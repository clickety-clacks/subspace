defmodule SubspaceWeb.IdentityStatusController do
  use SubspaceWeb, :controller
  plug :ensure_request_id_header

  alias Subspace.Identity.Config
  alias Subspace.Identity.Status
  alias Subspace.Identity.StatusRateLimiter

  @status_http_cache_table :subspace_identity_status_http_cache
  @cache_control_status "private, max-age=0, must-revalidate"
  @cache_control_rate_limited "private, no-store"
  @vary_status "authorization, if-none-match, if-modified-since"
  @schema_version_header "x-status-schema-version"
  @allow_methods "GET, HEAD, OPTIONS"
  @cache_control_options "private, no-store"
  @vary_options "authorization"
  @cache_control_unauthorized "private, no-store"
  @vary_unauthorized "authorization"

  def options(conn, _params) do
    case authorize_request(conn) do
      :ok ->
        conn
        |> put_resp_header(@schema_version_header, Status.schema_version())
        |> put_resp_header("allow", @allow_methods)
        |> put_resp_header("cache-control", @cache_control_options)
        |> put_resp_header("vary", @vary_options)
        |> send_resp(:no_content, "")

      :error ->
        conn
        |> put_resp_header("allow", @allow_methods)
        |> unauthorized_response()
    end
  end

  def method_not_allowed(conn, _params) do
    conn
    |> put_resp_header(@schema_version_header, Status.schema_version())
    |> put_resp_header("allow", @allow_methods)
    |> put_resp_header("cache-control", @cache_control_options)
    |> put_resp_header("vary", @vary_options)
    |> put_status(:method_not_allowed)
    |> json(%{error: "METHOD_NOT_ALLOWED"})
  end

  def show(conn, _params) do
    case authorize_request(conn) do
      :ok ->
        case allow_rate_limited_request?(conn) do
          :ok ->
            summary = Status.summary()
            {etag, last_modified} = cache_headers(summary)

            if resource_not_modified?(conn, etag, last_modified) do
              conn
              |> put_resp_header(@schema_version_header, Status.schema_version())
              |> put_resp_header("vary", @vary_status)
              |> put_resp_header("cache-control", @cache_control_status)
              |> put_resp_header("etag", etag)
              |> put_resp_header("last-modified", last_modified)
              |> send_resp(:not_modified, "")
            else
              conn
              |> put_resp_header(@schema_version_header, Status.schema_version())
              |> put_resp_header("vary", @vary_status)
              |> put_resp_header("cache-control", @cache_control_status)
              |> put_resp_header("etag", etag)
              |> put_resp_header("last-modified", last_modified)
              |> respond_with_body(:ok, summary)
            end

          {:error, retry_after_secs} ->
            conn
            |> put_resp_header("vary", @vary_status)
            |> put_resp_header("cache-control", @cache_control_rate_limited)
            |> put_resp_header("retry-after", Integer.to_string(retry_after_secs))
            |> respond_with_body(:too_many_requests, %{
              error: "RATE_LIMITED",
              retry_after_secs: retry_after_secs
            })
        end

      :error ->
        unauthorized_response(conn)
    end
  end

  defp authorize_request(conn) do
    case Config.identity_status_token() do
      token when is_binary(token) and token != "" ->
        case bearer_token(conn) do
          {:ok, provided} ->
            if valid_token?(provided, token), do: :ok, else: :error

          _ ->
            :error
        end

      _ ->
        :ok
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> :error
    end
  end

  defp valid_token?(provided, expected)
       when is_binary(provided) and is_binary(expected) and
              byte_size(provided) == byte_size(expected) do
    Plug.Crypto.secure_compare(provided, expected)
  end

  defp valid_token?(_provided, _expected), do: false

  defp allow_rate_limited_request?(conn) do
    client_id =
      conn.remote_ip
      |> :inet.ntoa()
      |> to_string()

    StatusRateLimiter.allow_with_retry(client_id)
  end

  defp build_etag(summary) do
    digest =
      summary
      |> etag_basis()
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    ~s("#{digest}")
  end

  defp cache_headers(summary) do
    etag = build_etag(summary)
    now_unix = DateTime.utc_now() |> DateTime.to_unix()
    ensure_status_http_cache_table!()

    last_modified_unix =
      case :ets.lookup(@status_http_cache_table, :status_basis) do
        [{:status_basis, %{etag: ^etag, last_modified_unix: cached_last_modified_unix}}]
        when is_integer(cached_last_modified_unix) ->
          cached_last_modified_unix

        _ ->
          :ets.insert(
            @status_http_cache_table,
            {:status_basis, %{etag: etag, last_modified_unix: now_unix}}
          )

          now_unix
      end

    {etag, httpdate(last_modified_unix)}
  end

  defp etag_basis(summary) do
    summary
    |> Map.update(:jwks_cache, %{}, &Map.delete(&1, :cache_age_secs))
    |> Map.update(:status_rate_limiter, %{}, &Map.delete(&1, :cleanup_age_secs))
  end

  defp resource_not_modified?(conn, etag, last_modified) do
    case get_req_header(conn, "if-none-match") do
      [] -> last_modified_match?(conn, last_modified)
      _ -> etag_match?(conn, etag)
    end
  end

  defp etag_match?(conn, etag) do
    case get_req_header(conn, "if-none-match") do
      [candidate | _] -> String.trim(candidate) == etag
      _ -> false
    end
  end

  defp last_modified_match?(conn, last_modified) do
    case get_req_header(conn, "if-modified-since") do
      [candidate | _] -> String.trim(candidate) == last_modified
      _ -> false
    end
  end

  defp httpdate(unix) when is_integer(unix) do
    unix
    |> DateTime.from_unix!()
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end

  defp ensure_status_http_cache_table! do
    case :ets.whereis(@status_http_cache_table) do
      :undefined ->
        :ets.new(@status_http_cache_table, [:named_table, :set, :public, read_concurrency: true])
        :ok

      _tid ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp respond_with_body(conn, status, body) do
    if head_request?(conn) do
      conn
      |> put_status(status)
      |> send_resp(Plug.Conn.Status.code(status), "")
    else
      conn
      |> put_status(status)
      |> json(body)
    end
  end

  defp head_request?(conn), do: conn.method == "HEAD"

  defp unauthorized_response(conn) do
    conn
    |> put_resp_header("cache-control", @cache_control_unauthorized)
    |> put_resp_header("vary", @vary_unauthorized)
    |> put_status(:unauthorized)
    |> json(%{error: "UNAUTHORIZED"})
  end

  defp ensure_request_id_header(conn, _opts) do
    case {get_resp_header(conn, "x-request-id"), conn.assigns[:request_id]} do
      {[], request_id} when is_binary(request_id) and request_id != "" ->
        put_resp_header(conn, "x-request-id", request_id)

      _ ->
        conn
    end
  end
end

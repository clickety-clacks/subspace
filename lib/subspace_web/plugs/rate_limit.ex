defmodule SubspaceWeb.Plugs.RateLimit do
  @moduledoc """
  Plug for rate limiting requests.

  Options:
    - scope: :register (keyed by IP) or :authenticated (keyed by agent_id)
  """

  import Plug.Conn

  alias Subspace.RateLimit.Store

  def init(opts), do: opts

  def call(conn, opts) do
    scope = Keyword.get(opts, :scope, :register)

    case check_limit(conn, scope) do
      :ok ->
        conn

      {:error, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: "rate limited", code: "RATE_LIMITED"}))
        |> halt()
    end
  end

  defp check_limit(conn, :register) do
    ip = extract_client_ip(conn)
    Store.check_rate_limit(:register, ip)
  end

  defp check_limit(conn, :authenticated) do
    case conn.assigns[:current_agent] do
      nil ->
        # No agent yet (auth plug hasn't run or failed)
        # Allow through - auth plug will handle rejection
        :ok

      agent ->
        Store.check_rate_limit(:post_message, agent.agent_id)
    end
  end

  defp extract_client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded
        |> String.split(",")
        |> List.first()
        |> String.trim()

      [] ->
        conn.remote_ip
        |> :inet.ntoa()
        |> to_string()
    end
  end
end

defmodule SubspaceWeb.IdentityStatusControllerTest do
  use SubspaceWeb.ConnCase, async: false

  alias Subspace.Identity.AssertionReplay
  alias Subspace.Identity.JwksCache
  alias Subspace.Identity.StatusRateLimiter
  alias Subspace.Repo

  setup do
    previous_identity = Application.get_env(:subspace, :identity, [])
    previous_status_now_unix_fn = Application.get_env(:subspace, :identity_status_now_unix_fn)
    clear_jwks_cache()
    clear_status_http_cache()
    StatusRateLimiter.clear()

    on_exit(fn ->
      Application.put_env(:subspace, :identity, previous_identity)
      restore_optional_env(:identity_status_now_unix_fn, previous_status_now_unix_fn)
      clear_jwks_cache()
      clear_status_http_cache()
      StatusRateLimiter.clear()
    end)

    :ok
  end

  test "returns identity status summary with config flags, jwks cache summary, and replay store status",
       %{
         conn: conn
       } do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    unique = System.unique_integer([:positive])
    jwks_url = "https://identity.example/.well-known/jwks.json"
    fetched_at_unix = DateTime.to_unix(now) - 5

    with_identity_config(
      mode: "external_service",
      issuer_url: "https://identity.example",
      issuer_jwks_url: jwks_url,
      service_id: "subspace-main",
      jwks_cache_ttl_secs: 300
    )

    :ok = JwksCache.put(jwks_url, [%{"kid" => "kid-#{unique}"}], fetched_at_unix)
    :ok = JwksCache.mark_forced_refresh(jwks_url, fetched_at_unix - 10)

    Repo.insert_all(AssertionReplay, [
      %{
        jti: "active_#{unique}",
        expires_at: DateTime.add(now, 60, :second),
        inserted_at: now,
        updated_at: now
      },
      %{
        jti: "expired_#{unique}",
        expires_at: DateTime.add(now, -60, :second),
        inserted_at: now,
        updated_at: now
      }
    ])

    request_id = "status-success-get-request-id"

    conn =
      conn
      |> put_req_header("x-request-id", request_id)
      |> get("/api/identity/status")

    assert body = json_response(conn, 200)
    assert get_resp_header(conn, "x-request-id") == [request_id]

    assert get_resp_header(conn, "x-status-schema-version") == ["1"]
    assert get_resp_header(conn, "x-status-schema-version") == [body["version"]]
    assert body["version"] == "1"
    assert body["mode"] == "external_service"
    assert body["issuer_configured"] == true
    assert body["issuer_jwks_configured"] == true
    assert body["service_id_configured"] == true
    refute Map.has_key?(body, "issuer_url")
    refute Map.has_key?(body, "service_id")

    assert jwks = body["jwks_cache"]
    assert jwks["configured"] == true
    assert jwks["entry_present"] == true
    assert jwks["key_count"] == 1
    assert jwks["fetched_at_unix"] == fetched_at_unix
    assert jwks["forced_refresh_at_unix"] == fetched_at_unix - 10
    assert jwks["cache_ttl_secs"] == 300
    assert is_integer(jwks["cache_age_secs"])
    refute Map.has_key?(jwks, "issuer_jwks_url")

    assert replay_store = body["replay_store"]
    assert replay_store["status"] == "ok"
    assert replay_store["total_entries"] == 2
    assert replay_store["active_entries"] == 1
    assert replay_store["expired_entries"] == 1

    assert limiter = body["status_rate_limiter"]
    assert limiter["enabled"] == true
    assert limiter["configured"] == true
    assert is_integer(limiter["tracked_clients"])
    assert limiter["tracked_clients"] >= 1
    assert is_integer(limiter["cleanup_age_secs"])
    refute Map.has_key?(limiter, "client_ids")
  end

  test "returns 401 when status token is configured and authorization header is missing", %{
    conn: conn
  } do
    with_identity_config(mode: "local_keypair", identity_status_token: "status-token")

    request_id = "status-unauthorized-get-request-id"

    conn =
      conn
      |> put_req_header("x-request-id", request_id)
      |> get("/api/identity/status")

    assert %{"error" => "UNAUTHORIZED"} = json_response(conn, 401)
    assert get_resp_header(conn, "x-request-id") == [request_id]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "vary") == ["authorization"]
  end

  test "generated request id header is present for get success when request header is missing", %{
    conn: conn
  } do
    with_identity_config(mode: "local_keypair")

    conn = get(conn, "/api/identity/status")
    assert _body = json_response(conn, 200)
    assert [request_id] = get_resp_header(conn, "x-request-id")
    assert byte_size(request_id) in 20..200
  end

  test "returns 401 when status token is configured and bearer token is invalid", %{conn: conn} do
    with_identity_config(mode: "local_keypair", identity_status_token: "status-token")

    conn =
      conn
      |> put_req_header("authorization", "Bearer wrong-token")
      |> get("/api/identity/status")

    assert %{"error" => "UNAUTHORIZED"} = json_response(conn, 401)
  end

  test "allows access when status token is configured and bearer token matches", %{conn: conn} do
    with_identity_config(mode: "local_keypair", identity_status_token: "status-token")

    conn =
      conn
      |> put_req_header("authorization", "Bearer status-token")
      |> get("/api/identity/status")

    assert body = json_response(conn, 200)
    assert body["mode"] == "local_keypair"
  end

  test "returns safe defaults when identity verifier dependencies are not configured", %{
    conn: conn
  } do
    with_identity_config(
      mode: "local_keypair",
      issuer_url: nil,
      issuer_jwks_url: nil,
      service_id: nil
    )

    conn = get(conn, "/api/identity/status")
    assert body = json_response(conn, 200)

    assert body["version"] == "1"
    assert body["mode"] == "local_keypair"
    assert body["issuer_configured"] == false
    assert body["issuer_jwks_configured"] == false
    assert body["service_id_configured"] == false

    assert jwks = body["jwks_cache"]
    assert jwks["configured"] == false
    assert jwks["entry_present"] == false
    assert jwks["key_count"] == 0
    assert jwks["fetched_at_unix"] == nil
    assert jwks["forced_refresh_at_unix"] == nil

    assert limiter = body["status_rate_limiter"]
    assert limiter["enabled"] == true
    assert limiter["configured"] == true
    assert is_integer(limiter["tracked_clients"])
    assert limiter["tracked_clients"] >= 1
    assert is_integer(limiter["cleanup_age_secs"])

    assert Map.has_key?(body, "jwks_cache")
    assert Map.has_key?(body, "replay_store")
    assert Map.has_key?(body, "status_rate_limiter")
  end

  test "identity status endpoint allows requests within configured rate limit", %{conn: conn} do
    with_identity_config(
      mode: "local_keypair",
      identity_status_rate_limit_max_requests: 2,
      identity_status_rate_limit_window_secs: 60
    )

    conn1 = get(conn, "/api/identity/status")
    assert _body1 = json_response(conn1, 200)

    conn2 = get(recycle(conn1), "/api/identity/status")
    assert _body2 = json_response(conn2, 200)
  end

  test "identity status endpoint returns 429 when rate limit is exceeded", %{conn: conn} do
    with_identity_config(
      mode: "local_keypair",
      identity_status_rate_limit_max_requests: 2,
      identity_status_rate_limit_window_secs: 60
    )

    conn = get(conn, "/api/identity/status")
    assert _body = json_response(conn, 200)

    conn = get(recycle(conn), "/api/identity/status")
    assert _body = json_response(conn, 200)

    request_id = "status-rate-limited-request-id"

    conn =
      conn
      |> recycle()
      |> put_req_header("x-request-id", request_id)
      |> get("/api/identity/status")

    assert %{"error" => "RATE_LIMITED", "retry_after_secs" => retry_after_secs} =
             json_response(conn, 429)

    assert get_resp_header(conn, "x-request-id") == [request_id]
    assert is_integer(retry_after_secs)
    assert retry_after_secs >= 1
    assert retry_after_secs <= 60
    assert get_resp_header(conn, "vary") == ["authorization, if-none-match, if-modified-since"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "retry-after") == [Integer.to_string(retry_after_secs)]
  end

  test "varying x-forwarded-for does not evade identity status rate limit", %{conn: conn} do
    with_identity_config(
      mode: "local_keypair",
      identity_status_rate_limit_max_requests: 2,
      identity_status_rate_limit_window_secs: 60
    )

    conn =
      conn
      |> put_req_header("x-forwarded-for", "198.51.100.1")
      |> get("/api/identity/status")

    assert _body = json_response(conn, 200)

    conn =
      conn
      |> recycle()
      |> put_req_header("x-forwarded-for", "203.0.113.2")
      |> get("/api/identity/status")

    assert _body = json_response(conn, 200)

    conn =
      conn
      |> recycle()
      |> put_req_header("x-forwarded-for", "192.0.2.3")
      |> get("/api/identity/status")

    assert %{"error" => "RATE_LIMITED"} = json_response(conn, 429)
  end

  test "invalid limiter config reports enabled runtime with configured false and still enforces",
       %{
         conn: conn
       } do
    with_identity_config(
      mode: "local_keypair",
      identity_status_rate_limit_max_requests: 0,
      identity_status_rate_limit_window_secs: -1
    )

    conn = get(conn, "/api/identity/status")
    assert body = json_response(conn, 200)

    assert limiter = body["status_rate_limiter"]
    assert limiter["enabled"] == true
    assert limiter["configured"] == false

    conn_after_allowed =
      Enum.reduce(1..29, conn, fn _, acc ->
        req_conn = get(recycle(acc), "/api/identity/status")
        assert _body = json_response(req_conn, 200)
        req_conn
      end)

    limited_conn = get(recycle(conn_after_allowed), "/api/identity/status")

    assert %{"error" => "RATE_LIMITED", "retry_after_secs" => retry_after_secs} =
             json_response(limited_conn, 429)

    assert is_integer(retry_after_secs)
    assert retry_after_secs >= 1
    assert get_resp_header(limited_conn, "retry-after") == [Integer.to_string(retry_after_secs)]
  end

  test "identity status endpoint supports conditional get with etag and 304", %{conn: conn} do
    with_identity_config(mode: "local_keypair")

    first_conn = get(conn, "/api/identity/status")
    assert _body = json_response(first_conn, 200)

    assert get_resp_header(first_conn, "vary") == [
             "authorization, if-none-match, if-modified-since"
           ]

    assert get_resp_header(first_conn, "cache-control") == ["private, max-age=0, must-revalidate"]
    assert [etag] = get_resp_header(first_conn, "etag")
    assert [last_modified] = get_resp_header(first_conn, "last-modified")
    assert String.starts_with?(etag, "\"")
    assert String.ends_with?(etag, "\"")
    assert String.contains?(last_modified, "GMT")

    second_conn =
      first_conn
      |> recycle()
      |> put_req_header("if-none-match", etag)
      |> get("/api/identity/status")

    assert response(second_conn, 304) == ""

    assert get_resp_header(second_conn, "vary") == [
             "authorization, if-none-match, if-modified-since"
           ]

    assert get_resp_header(second_conn, "cache-control") == [
             "private, max-age=0, must-revalidate"
           ]

    assert get_resp_header(second_conn, "etag") == [etag]
    assert get_resp_header(second_conn, "last-modified") == [last_modified]
    assert get_resp_header(second_conn, "x-status-schema-version") == ["1"]
  end

  test "conditional get remains 304 when only time-derived status fields change", %{conn: conn} do
    with_identity_config(mode: "local_keypair")

    {:ok, time_pid} = Agent.start_link(fn -> 1_700_000_000 end)

    Application.put_env(:subspace, :identity_status_now_unix_fn, fn ->
      Agent.get(time_pid, & &1)
    end)

    first_conn = get(conn, "/api/identity/status")
    assert _body = json_response(first_conn, 200)
    assert [etag] = get_resp_header(first_conn, "etag")

    Agent.update(time_pid, &(&1 + 30))

    second_conn =
      first_conn
      |> recycle()
      |> put_req_header("if-none-match", etag)
      |> get("/api/identity/status")

    assert response(second_conn, 304) == ""
    assert get_resp_header(second_conn, "etag") == [etag]
  end

  test "identity status endpoint returns 304 for matching if-modified-since on unchanged state",
       %{
         conn: conn
       } do
    with_identity_config(mode: "local_keypair")

    {:ok, time_pid} = Agent.start_link(fn -> 1_700_000_000 end)

    Application.put_env(:subspace, :identity_status_now_unix_fn, fn ->
      Agent.get(time_pid, & &1)
    end)

    first_conn = get(conn, "/api/identity/status")
    assert _body = json_response(first_conn, 200)
    assert [last_modified] = get_resp_header(first_conn, "last-modified")

    Agent.update(time_pid, &(&1 + 30))

    second_conn =
      first_conn
      |> recycle()
      |> put_req_header("if-modified-since", last_modified)
      |> get("/api/identity/status")

    assert response(second_conn, 304) == ""
    assert get_resp_header(second_conn, "last-modified") == [last_modified]
  end

  test "if-none-match takes precedence over if-modified-since when validators conflict", %{
    conn: conn
  } do
    with_identity_config(mode: "local_keypair")

    first_conn = get(conn, "/api/identity/status")
    assert _body = json_response(first_conn, 200)
    assert [etag] = get_resp_header(first_conn, "etag")
    assert [last_modified] = get_resp_header(first_conn, "last-modified")

    second_conn =
      first_conn
      |> recycle()
      |> put_req_header("if-none-match", ~s("etag-mismatch"))
      |> put_req_header("if-modified-since", last_modified)
      |> get("/api/identity/status")

    assert _body = json_response(second_conn, 200)
    assert get_resp_header(second_conn, "etag") == [etag]
    assert get_resp_header(second_conn, "last-modified") == [last_modified]
  end

  test "head status returns 200 with validators headers and no body", %{conn: conn} do
    with_identity_config(mode: "local_keypair")

    request_id = "status-success-head-request-id"

    conn =
      conn
      |> put_req_header("x-request-id", request_id)
      |> head("/api/identity/status")

    assert response(conn, 200) == ""
    assert get_resp_header(conn, "x-request-id") == [request_id]
    assert get_resp_header(conn, "etag") != []
    assert get_resp_header(conn, "last-modified") != []
    assert get_resp_header(conn, "cache-control") == ["private, max-age=0, must-revalidate"]
    assert get_resp_header(conn, "vary") == ["authorization, if-none-match, if-modified-since"]
    assert get_resp_header(conn, "x-status-schema-version") == ["1"]
  end

  test "head status returns 401 with auth policy headers when token is configured and authorization header is missing",
       %{
         conn: conn
       } do
    with_identity_config(mode: "local_keypair", identity_status_token: "status-token")

    request_id = "status-unauthorized-head-request-id"

    conn =
      conn
      |> put_req_header("x-request-id", request_id)
      |> head("/api/identity/status")

    assert response(conn, 401) == ""
    assert get_resp_header(conn, "x-request-id") == [request_id]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "vary") == ["authorization"]
  end

  test "generated request id header is present for head unauthorized when request header is missing",
       %{
         conn: conn
       } do
    with_identity_config(mode: "local_keypair", identity_status_token: "status-token")

    conn = head(conn, "/api/identity/status")
    assert response(conn, 401) == ""
    assert [request_id] = get_resp_header(conn, "x-request-id")
    assert byte_size(request_id) in 20..200
  end

  test "head status returns 304 with validators headers and no body for matching if-none-match",
       %{
         conn: conn
       } do
    with_identity_config(mode: "local_keypair")

    first_conn = head(conn, "/api/identity/status")
    assert response(first_conn, 200) == ""
    assert [etag] = get_resp_header(first_conn, "etag")
    assert [last_modified] = get_resp_header(first_conn, "last-modified")

    second_conn =
      first_conn
      |> recycle()
      |> put_req_header("if-none-match", etag)
      |> head("/api/identity/status")

    assert response(second_conn, 304) == ""
    assert get_resp_header(second_conn, "etag") == [etag]
    assert get_resp_header(second_conn, "last-modified") == [last_modified]

    assert get_resp_header(second_conn, "cache-control") == [
             "private, max-age=0, must-revalidate"
           ]

    assert get_resp_header(second_conn, "vary") == [
             "authorization, if-none-match, if-modified-since"
           ]

    assert get_resp_header(second_conn, "x-status-schema-version") == ["1"]
  end

  test "head if-none-match takes precedence over if-modified-since when validators conflict", %{
    conn: conn
  } do
    with_identity_config(mode: "local_keypair")

    first_conn = head(conn, "/api/identity/status")
    assert response(first_conn, 200) == ""
    assert [etag] = get_resp_header(first_conn, "etag")
    assert [last_modified] = get_resp_header(first_conn, "last-modified")

    second_conn =
      first_conn
      |> recycle()
      |> put_req_header("if-none-match", ~s("etag-mismatch"))
      |> put_req_header("if-modified-since", last_modified)
      |> head("/api/identity/status")

    assert response(second_conn, 200) == ""
    assert get_resp_header(second_conn, "etag") == [etag]
    assert get_resp_header(second_conn, "last-modified") == [last_modified]
  end

  test "head returns 304 when both validators are present and if-none-match matches", %{
    conn: conn
  } do
    with_identity_config(mode: "local_keypair")

    first_conn = head(conn, "/api/identity/status")
    assert response(first_conn, 200) == ""
    assert [etag] = get_resp_header(first_conn, "etag")

    second_conn =
      first_conn
      |> recycle()
      |> put_req_header("if-none-match", etag)
      |> put_req_header("if-modified-since", "Wed, 01 Jan 1970 00:00:00 GMT")
      |> head("/api/identity/status")

    assert response(second_conn, 304) == ""
    assert get_resp_header(second_conn, "etag") == [etag]
  end

  test "head status returns 429 with rate-limit headers and no body", %{conn: conn} do
    with_identity_config(
      mode: "local_keypair",
      identity_status_rate_limit_max_requests: 1,
      identity_status_rate_limit_window_secs: 60
    )

    first_conn = head(conn, "/api/identity/status")
    assert response(first_conn, 200) == ""

    second_conn = head(recycle(first_conn), "/api/identity/status")
    assert response(second_conn, 429) == ""
    assert get_resp_header(second_conn, "retry-after") != []
    assert get_resp_header(second_conn, "cache-control") == ["private, no-store"]

    assert get_resp_header(second_conn, "vary") == [
             "authorization, if-none-match, if-modified-since"
           ]
  end

  test "options status returns 401 when token is configured and authorization header is missing",
       %{
         conn: conn
       } do
    with_identity_config(mode: "local_keypair", identity_status_token: "status-token")

    request_id = "status-unauthorized-options-request-id"

    conn =
      conn
      |> put_req_header("x-request-id", request_id)
      |> options("/api/identity/status")

    assert %{"error" => "UNAUTHORIZED"} = json_response(conn, 401)
    assert get_resp_header(conn, "x-request-id") == [request_id]
    assert get_resp_header(conn, "allow") == ["GET, HEAD, OPTIONS"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "vary") == ["authorization"]
    assert get_resp_header(conn, "x-status-schema-version") == []
  end

  test "generated request id header is present for options unauthorized when request header is missing",
       %{
         conn: conn
       } do
    with_identity_config(mode: "local_keypair", identity_status_token: "status-token")

    conn = options(conn, "/api/identity/status")
    assert %{"error" => "UNAUTHORIZED"} = json_response(conn, 401)
    assert [request_id] = get_resp_header(conn, "x-request-id")
    assert byte_size(request_id) in 20..200
  end

  test "options status returns 401 when token is configured and bearer token is invalid", %{
    conn: conn
  } do
    with_identity_config(mode: "local_keypair", identity_status_token: "status-token")

    conn =
      conn
      |> put_req_header("authorization", "Bearer wrong-token")
      |> options("/api/identity/status")

    assert %{"error" => "UNAUTHORIZED"} = json_response(conn, 401)
    assert get_resp_header(conn, "allow") == ["GET, HEAD, OPTIONS"]
    assert get_resp_header(conn, "x-status-schema-version") == []
  end

  test "options status returns 204 with headers when token is configured and bearer token matches",
       %{
         conn: conn
       } do
    with_identity_config(mode: "local_keypair", identity_status_token: "status-token")
    request_id = "status-success-options-request-id"

    conn =
      conn
      |> put_req_header("x-request-id", request_id)
      |> put_req_header("authorization", "Bearer status-token")
      |> options("/api/identity/status")

    assert response(conn, 204) == ""
    assert get_resp_header(conn, "x-request-id") == [request_id]
    assert get_resp_header(conn, "x-status-schema-version") == ["1"]
    assert get_resp_header(conn, "allow") == ["GET, HEAD, OPTIONS"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "vary") == ["authorization"]
  end

  test "options status remains open and returns 204 when token is unset", %{conn: conn} do
    with_identity_config(mode: "local_keypair", identity_status_token: nil)

    conn = options(conn, "/api/identity/status")

    assert response(conn, 204) == ""
    assert get_resp_header(conn, "x-status-schema-version") == ["1"]
    assert get_resp_header(conn, "allow") == ["GET, HEAD, OPTIONS"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "vary") == ["authorization"]
  end

  test "unsupported identity status methods return 405 with allow header", %{conn: conn} do
    request_id = "status-method-not-allowed-request-id"

    post_conn =
      conn
      |> put_req_header("x-request-id", request_id)
      |> post("/api/identity/status", %{})

    assert %{"error" => "METHOD_NOT_ALLOWED"} = json_response(post_conn, 405)
    assert get_resp_header(post_conn, "x-request-id") == [request_id]
    assert get_resp_header(post_conn, "x-status-schema-version") == ["1"]
    assert get_resp_header(post_conn, "allow") == ["GET, HEAD, OPTIONS"]
    assert get_resp_header(post_conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(post_conn, "vary") == ["authorization"]

    put_conn = put(recycle(post_conn), "/api/identity/status", %{})
    assert %{"error" => "METHOD_NOT_ALLOWED"} = json_response(put_conn, 405)
    assert get_resp_header(put_conn, "x-status-schema-version") == ["1"]
    assert get_resp_header(put_conn, "allow") == ["GET, HEAD, OPTIONS"]
    assert get_resp_header(put_conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(put_conn, "vary") == ["authorization"]

    patch_conn = patch(recycle(put_conn), "/api/identity/status", %{})
    assert %{"error" => "METHOD_NOT_ALLOWED"} = json_response(patch_conn, 405)
    assert get_resp_header(patch_conn, "x-status-schema-version") == ["1"]
    assert get_resp_header(patch_conn, "allow") == ["GET, HEAD, OPTIONS"]
    assert get_resp_header(patch_conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(patch_conn, "vary") == ["authorization"]

    delete_conn = delete(recycle(patch_conn), "/api/identity/status")
    assert %{"error" => "METHOD_NOT_ALLOWED"} = json_response(delete_conn, 405)
    assert get_resp_header(delete_conn, "x-status-schema-version") == ["1"]
    assert get_resp_header(delete_conn, "allow") == ["GET, HEAD, OPTIONS"]
    assert get_resp_header(delete_conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(delete_conn, "vary") == ["authorization"]
  end

  defp with_identity_config(overrides) do
    previous_identity = Application.get_env(:subspace, :identity, [])
    updated = Keyword.merge(previous_identity, overrides)
    Application.put_env(:subspace, :identity, updated)

    on_exit(fn ->
      Application.put_env(:subspace, :identity, previous_identity)
    end)
  end

  defp clear_jwks_cache do
    case :ets.whereis(:subspace_identity_jwks_cache) do
      :undefined -> :ok
      _tid -> :ets.delete_all_objects(:subspace_identity_jwks_cache)
    end
  end

  defp clear_status_http_cache do
    case :ets.whereis(:subspace_identity_status_http_cache) do
      :undefined -> :ok
      _tid -> :ets.delete_all_objects(:subspace_identity_status_http_cache)
    end
  end

  defp restore_optional_env(key, nil), do: Application.delete_env(:subspace, key)
  defp restore_optional_env(key, value), do: Application.put_env(:subspace, key, value)
end

defmodule SubspaceWeb.AgentControllerIdentityTest do
  use SubspaceWeb.ConnCase, async: true

  test "phase-1 register + reauth happy path uses camelCase API and owner" do
    with_identity_config(local_challenge_ttl_secs: 120)

    {public_key, private_key} = generate_ed25519_keypair()

    conn =
      post(build_conn(), "/api/agents/register/start", %{
        "name" => "clu",
        "owner" => "flynn",
        "publicKey" => public_key
      })

    assert %{"challengeId" => challenge_id, "challenge" => challenge} = json_response(conn, 200)

    register_signature =
      sign_payload(private_key, %{
        "challenge" => challenge,
        "name" => "clu",
        "owner" => "flynn",
        "publicKey" => public_key
      })

    conn =
      post(build_conn(), "/api/agents/register/verify", %{
        "challengeId" => challenge_id,
        "name" => "clu",
        "owner" => "flynn",
        "publicKey" => public_key,
        "signature" => register_signature
      })

    assert %{
             "agentId" => ^public_key,
             "name" => "clu",
             "owner" => "flynn",
             "sessionToken" => first_token
           } = json_response(conn, 201)

    assert String.length(first_token) == 64

    conn = post(build_conn(), "/api/agents/reauth/start", %{"agentId" => public_key})
    assert %{"challengeId" => challenge_id, "challenge" => challenge} = json_response(conn, 200)

    reauth_signature =
      sign_payload(private_key, %{
        "challenge" => challenge,
        "agentId" => public_key
      })

    conn =
      post(build_conn(), "/api/agents/reauth/verify", %{
        "challengeId" => challenge_id,
        "agentId" => public_key,
        "signature" => reauth_signature
      })

    assert %{"agentId" => ^public_key, "sessionToken" => second_token} = json_response(conn, 200)
    assert String.length(second_token) == 64
    refute second_token == first_token
  end

  test "register/start validates required owner", %{conn: conn} do
    with_identity_config()

    conn = post(conn, "/api/agents/register/start", %{"name" => "clu", "publicKey" => "pk"})
    assert %{"error" => "invalid input", "code" => "INVALID_INPUT"} = json_response(conn, 400)
  end

  test "register/verify fails signature and consumes challenge", %{conn: conn} do
    with_identity_config(local_challenge_ttl_secs: 120)

    {public_key, private_key} = generate_ed25519_keypair()

    conn =
      post(conn, "/api/agents/register/start", %{
        "name" => "clu",
        "owner" => "flynn",
        "publicKey" => public_key
      })

    assert %{"challengeId" => challenge_id, "challenge" => challenge} = json_response(conn, 200)

    bad_signature = :crypto.strong_rand_bytes(64) |> b64url()

    conn =
      post(conn, "/api/agents/register/verify", %{
        "challengeId" => challenge_id,
        "name" => "clu",
        "owner" => "flynn",
        "publicKey" => public_key,
        "signature" => bad_signature
      })

    assert %{"error" => "forbidden", "code" => "SIGNATURE_INVALID"} = json_response(conn, 403)

    valid_signature =
      sign_payload(private_key, %{
        "challenge" => challenge,
        "name" => "clu",
        "owner" => "flynn",
        "publicKey" => public_key
      })

    conn =
      post(conn, "/api/agents/register/verify", %{
        "challengeId" => challenge_id,
        "name" => "clu",
        "owner" => "flynn",
        "publicKey" => public_key,
        "signature" => valid_signature
      })

    assert %{"error" => "forbidden", "code" => "SIGNATURE_INVALID"} = json_response(conn, 403)
  end

  test "phase-1 does not expose IDS register endpoint", %{conn: conn} do
    conn = post(conn, "/api/agents/register", %{"identity_assertion" => "abc"})

    assert %{"error" => "not found", "code" => "NOT_FOUND"} = json_response(conn, 404)
  end

  test "phase-1 does not expose IDS reauth endpoint", %{conn: conn} do
    conn =
      post(conn, "/api/agents/reauth", %{"agentId" => "id_1", "identity_assertion" => "abc"})

    assert %{"error" => "not found", "code" => "NOT_FOUND"} = json_response(conn, 404)
  end

  defp with_identity_config(overrides \\ []) do
    previous_identity = Application.get_env(:subspace, :identity, [])

    updated =
      previous_identity
      |> Keyword.merge(mode: "local_keypair")
      |> Keyword.merge(overrides)

    Application.put_env(:subspace, :identity, updated)

    on_exit(fn ->
      Application.put_env(:subspace, :identity, previous_identity)
    end)
  end

  defp generate_ed25519_keypair do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    {b64url(public_key), private_key}
  end

  defp sign_payload(private_key, payload_map) do
    payload = payload_map |> Jason.encode!()

    signature = :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])
    b64url(signature)
  end

  defp b64url(binary) do
    binary
    |> Base.url_encode64(padding: false)
  end
end

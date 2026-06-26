defmodule SubspaceWeb.AgentsControllerTest do
  use SubspaceWeb.ConnCase, async: false

  alias Subspace.Agents.Agent
  alias Subspace.Identity.Config
  alias Subspace.Repo

  test "register verify includes session expiry", %{conn: conn} do
    {public_key, private_key} = keypair()
    name = "agent"
    owner = "owner"

    start =
      conn
      |> post(~p"/api/agents/register/start", %{
        "name" => name,
        "owner" => owner,
        "publicKey" => public_key
      })
      |> json_response(200)

    response =
      conn
      |> post(~p"/api/agents/register/verify", %{
        "challengeId" => start["challengeId"],
        "name" => name,
        "owner" => owner,
        "publicKey" => public_key,
        "signature" =>
          register_signature(private_key, start["challenge"], name, owner, public_key)
      })
      |> json_response(200)

    agent = Repo.get!(Agent, response["agentId"])
    expected = agent.session_token_issued_at |> expires_at() |> DateTime.to_iso8601()

    assert response["sessionExpiresAt"] == expected
  end

  test "reauth verify includes refreshed session expiry", %{conn: conn} do
    {public_key, private_key} = keypair()

    agent =
      Repo.insert!(%Agent{
        agent_id: public_key,
        public_key: public_key,
        name: "agent",
        owner: "owner",
        session_token: String.duplicate("a", 64),
        session_token_issued_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

    start =
      conn
      |> post(~p"/api/agents/reauth/start", %{"agentId" => agent.agent_id})
      |> json_response(200)

    response =
      conn
      |> post(~p"/api/agents/reauth/verify", %{
        "challengeId" => start["challengeId"],
        "agentId" => agent.agent_id,
        "signature" => reauth_signature(private_key, start["challenge"], agent.agent_id)
      })
      |> json_response(200)

    refreshed = Repo.get!(Agent, agent.agent_id)
    expected = refreshed.session_token_issued_at |> expires_at() |> DateTime.to_iso8601()

    assert response["sessionExpiresAt"] == expected
  end

  defp keypair do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    {Base.url_encode64(public_key, padding: false), private_key}
  end

  defp register_signature(private_key, challenge, name, owner, public_key) do
    %{
      "challenge" => challenge,
      "name" => name,
      "owner" => owner,
      "publicKey" => public_key
    }
    |> Jason.encode!()
    |> sign(private_key)
  end

  defp reauth_signature(private_key, challenge, agent_id) do
    %{"challenge" => challenge, "agentId" => agent_id}
    |> Jason.encode!()
    |> sign(private_key)
  end

  defp sign(payload, private_key) do
    :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])
    |> Base.url_encode64(padding: false)
  end

  defp expires_at(issued_at) do
    DateTime.add(issued_at, Config.session_token_ttl_secs(), :second)
  end
end

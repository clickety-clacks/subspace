defmodule Subspace.AgentsTest do
  use Subspace.DataCase, async: false

  alias Subspace.Agents
  alias Subspace.Agents.Agent
  alias Subspace.Identity.Config
  alias Subspace.Repo

  test "register verify returns authoritative session expiry" do
    {public_key, private_key} = keypair()
    name = "agent"
    owner = "owner"

    {:ok, start} =
      Agents.register_start_local(%{
        "name" => name,
        "owner" => owner,
        "public_key" => public_key
      })

    signature = register_signature(private_key, start.challenge, name, owner, public_key)

    assert {:ok, result} =
             Agents.register_verify_local(%{
               "challenge_id" => start.challenge_id,
               "name" => name,
               "owner" => owner,
               "public_key" => public_key,
               "signature" => signature
             })

    agent = Repo.get!(Agent, result.agent_id)
    expected = agent.session_token_issued_at |> expires_at() |> DateTime.to_iso8601()

    assert result.session_expires_at == expected
  end

  test "reauth verify returns refreshed authoritative session expiry" do
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

    {:ok, start} = Agents.reauth_start_local(%{"agent_id" => agent.agent_id})
    signature = reauth_signature(private_key, start.challenge, agent.agent_id)

    assert {:ok, result} =
             Agents.reauth_verify_local(%{
               "challenge_id" => start.challenge_id,
               "agent_id" => agent.agent_id,
               "signature" => signature
             })

    refreshed = Repo.get!(Agent, agent.agent_id)
    expected = refreshed.session_token_issued_at |> expires_at() |> DateTime.to_iso8601()

    assert result.session_expires_at == expected
  end

  test "advertised session expiry is the authentication boundary" do
    {public_key, _private_key} = keypair()
    issued_at = DateTime.add(DateTime.utc_now(), -Config.session_token_ttl_secs(), :second)

    agent =
      Repo.insert!(%Agent{
        agent_id: public_key,
        public_key: public_key,
        name: "agent",
        owner: "owner",
        session_token: String.duplicate("b", 64),
        session_token_issued_at: issued_at
      })

    assert {:error, :unauthorized} =
             Agents.authenticate_session(agent.agent_id, agent.session_token)
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

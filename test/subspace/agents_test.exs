defmodule Subspace.AgentsTest do
  use Subspace.DataCase, async: false

  alias Subspace.Agents
  alias Subspace.Agents.Agent
  alias Subspace.Identity.Config
  alias Subspace.Repo

  setup do
    identity_config = Application.get_env(:subspace, :identity, [])

    Application.put_env(
      :subspace,
      :identity,
      Keyword.put(identity_config, :trusted_machine_agent_ids, [])
    )

    on_exit(fn -> Application.put_env(:subspace, :identity, identity_config) end)
  end

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

    assert {:error, :token_revoked} =
             Agents.authorize_ws_join(agent.agent_id, agent.session_token)
  end

  test "trusted machine registration has no finite expiry and old sessions remain valid" do
    {public_key, private_key} = keypair()
    trust_machine(public_key)

    {:ok, start} =
      Agents.register_start_local(%{
        "name" => "machine",
        "owner" => "operator",
        "public_key" => public_key
      })

    signature =
      register_signature(private_key, start.challenge, "machine", "operator", public_key)

    assert {:ok, %{session_expires_at: nil} = result} =
             Agents.register_verify_local(%{
               "challenge_id" => start.challenge_id,
               "name" => "machine",
               "owner" => "operator",
               "public_key" => public_key,
               "signature" => signature
             })

    old_issued_at =
      DateTime.add(DateTime.utc_now(), -Config.session_token_ttl_secs() - 1, :second)

    Agent
    |> Repo.get!(result.agent_id)
    |> Ecto.Changeset.change(session_token_issued_at: old_issued_at)
    |> Repo.update!()

    assert {:ok, %Agent{agent_id: ^public_key}} =
             Agents.authenticate_session(public_key, result.session_token)

    assert {:ok, %Agent{agent_id: ^public_key}} =
             Agents.authorize_ws_join(public_key, result.session_token)

    assert {:error, :token_invalid} = Agents.authorize_ws_join(public_key, "malformed")

    near_match_id = public_key <> "-other"

    near_match =
      Repo.insert!(%Agent{
        agent_id: near_match_id,
        public_key: near_match_id,
        name: "near-match",
        owner: "operator",
        session_token: String.duplicate("e", 64),
        session_token_issued_at: old_issued_at
      })

    assert {:error, :token_revoked} =
             Agents.authorize_ws_join(near_match.agent_id, near_match.session_token)
  end

  test "trusted machine reauth rotates its token without adding an expiry" do
    {public_key, private_key} = keypair()
    trust_machine(public_key)
    old_token = String.duplicate("c", 64)

    Repo.insert!(%Agent{
      agent_id: public_key,
      public_key: public_key,
      name: "machine",
      owner: "operator",
      session_token: old_token,
      session_token_issued_at: DateTime.utc_now()
    })

    {:ok, start} = Agents.reauth_start_local(%{"agent_id" => public_key})
    signature = reauth_signature(private_key, start.challenge, public_key)

    assert {:ok, %{session_expires_at: nil, session_token: new_token}} =
             Agents.reauth_verify_local(%{
               "challenge_id" => start.challenge_id,
               "agent_id" => public_key,
               "signature" => signature
             })

    refute new_token == old_token
    assert {:error, :token_invalid} = Agents.authorize_ws_join(public_key, old_token)
    assert {:ok, %Agent{agent_id: ^public_key}} = Agents.authorize_ws_join(public_key, new_token)
  end

  test "trusted machine sessions still expose explicit revocation and ban" do
    {public_key, _private_key} = keypair()
    trust_machine(public_key)
    token = String.duplicate("d", 64)

    agent =
      Repo.insert!(%Agent{
        agent_id: public_key,
        public_key: public_key,
        name: "machine",
        owner: "operator",
        session_token: token,
        session_token_issued_at:
          DateTime.add(DateTime.utc_now(), -Config.session_token_ttl_secs() - 1, :second)
      })

    agent
    |> Ecto.Changeset.change(session_token: nil)
    |> Repo.update!()

    assert {:error, :token_revoked} = Agents.authorize_ws_join(public_key, token)

    agent
    |> Ecto.Changeset.change(banned_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:error, :banned} = Agents.authorize_ws_join(public_key, token)
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

  defp trust_machine(agent_id) do
    identity_config = Application.get_env(:subspace, :identity, [])

    Application.put_env(
      :subspace,
      :identity,
      Keyword.put(identity_config, :trusted_machine_agent_ids, [agent_id])
    )
  end
end

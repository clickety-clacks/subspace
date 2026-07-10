defmodule SubspaceWeb.AgentsControllerTest do
  use SubspaceWeb.ConnCase, async: false

  alias Subspace.Agents.Agent
  alias Subspace.Identity.Config
  alias Subspace.Repo

  setup do
    identity_config = Application.get_env(:subspace, :identity, [])
    trusted_machine_env = System.get_env("TRUSTED_MACHINE_AGENT_IDS")

    Application.put_env(
      :subspace,
      :identity,
      Keyword.put(identity_config, :trusted_machine_agent_ids, [])
    )

    on_exit(fn ->
      Application.put_env(:subspace, :identity, identity_config)
      restore_env("TRUSTED_MACHINE_AGENT_IDS", trusted_machine_env)
    end)
  end

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

  test "trusted machine registration and reauth return null session expiry", %{conn: conn} do
    {public_key, private_key} = keypair()
    trust_machine(public_key)

    start =
      conn
      |> post(~p"/api/agents/register/start", %{
        "name" => "machine",
        "owner" => "operator",
        "publicKey" => public_key
      })
      |> json_response(200)

    registration =
      conn
      |> post(~p"/api/agents/register/verify", %{
        "challengeId" => start["challengeId"],
        "name" => "machine",
        "owner" => "operator",
        "publicKey" => public_key,
        "signature" =>
          register_signature(
            private_key,
            start["challenge"],
            "machine",
            "operator",
            public_key
          )
      })
      |> json_response(200)

    assert registration["agentId"] == public_key
    assert registration["sessionExpiresAt"] == nil

    reauth_start =
      conn
      |> post(~p"/api/agents/reauth/start", %{"agentId" => public_key})
      |> json_response(200)

    reauth =
      conn
      |> post(~p"/api/agents/reauth/verify", %{
        "challengeId" => reauth_start["challengeId"],
        "agentId" => public_key,
        "signature" => reauth_signature(private_key, reauth_start["challenge"], public_key)
      })
      |> json_response(200)

    assert reauth["sessionExpiresAt"] == nil
    refute reauth["sessionToken"] == registration["sessionToken"]
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
    System.put_env("TRUSTED_MACHINE_AGENT_IDS", " #{agent_id} ")

    identity_config =
      "config/runtime.exs"
      |> Elixir.Config.Reader.read!(env: :test)
      |> get_in([:subspace, :identity])

    Application.put_env(:subspace, :identity, identity_config)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end

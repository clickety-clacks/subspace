defmodule Subspace.Agents do
  @moduledoc false

  alias Ecto.Changeset
  alias Subspace.Agents.Agent
  alias Subspace.Identity.Config
  alias Subspace.Identity.LocalKeypairVerifier
  alias Subspace.Repo

  @session_token_pattern ~r/\A[a-f0-9]{64}\z/
  @challenge_table :subspace_agent_auth_challenges

  def register_start_local(%{"name" => name, "owner" => owner, "public_key" => public_key}) do
    challenge_id = "chg_" <> random_id(12)
    challenge = random_hex(32)
    now = now_utc()

    attrs = %{
      challenge_id: challenge_id,
      flow: "register",
      challenge: challenge,
      name: name,
      owner: owner,
      public_key: public_key,
      expires_at: DateTime.add(now, Config.local_challenge_ttl_secs(), :second)
    }

    ensure_challenge_table!()
    true = :ets.insert(@challenge_table, {challenge_id, attrs})
    {:ok, %{challenge_id: challenge_id, challenge: challenge}}
  end

  def register_verify_local(%{
        "challenge_id" => challenge_id,
        "name" => name,
        "owner" => owner,
        "public_key" => public_key,
        "signature" => signature
      }) do
    with {:ok, challenge} <- consume_active_challenge(challenge_id, "register"),
         :ok <- validate_register_challenge(challenge, name, owner, public_key),
         :ok <-
           LocalKeypairVerifier.verify_register_signature(
             challenge.challenge,
             name,
             owner,
             public_key,
             signature
           ) do
      token = session_token()
      now = now_utc()

      attrs = %{
        agent_id: public_key,
        public_key: public_key,
        name: name,
        owner: owner,
        session_token: token,
        session_token_issued_at: now
      }

      %Agent{}
      |> Agent.registration_changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, agent} ->
          {:ok,
           %{agent_id: agent.agent_id, session_token: token, name: agent.name, owner: agent.owner}}

        {:error, %Changeset{}} ->
          {:error, :already_registered}
      end
    end
  end

  def reauth_start_local(%{"agent_id" => agent_id}) do
    case Repo.get(Agent, agent_id) do
      nil ->
        {:error, :not_found}

      %Agent{} = agent ->
        with :ok <- ensure_not_banned(agent) do
          challenge_id = "chg_" <> random_id(12)
          challenge = random_hex(32)
          now = now_utc()

          attrs = %{
            challenge_id: challenge_id,
            flow: "reauth",
            challenge: challenge,
            agent_id: agent_id,
            expires_at: DateTime.add(now, Config.local_challenge_ttl_secs(), :second)
          }

          ensure_challenge_table!()
          true = :ets.insert(@challenge_table, {challenge_id, attrs})
          {:ok, %{challenge_id: challenge_id, challenge: challenge}}
        end
    end
  end

  def reauth_verify_local(%{
        "challenge_id" => challenge_id,
        "agent_id" => agent_id,
        "signature" => signature
      }) do
    with {:ok, challenge} <- consume_active_challenge(challenge_id, "reauth"),
         :ok <- validate_reauth_challenge(challenge, agent_id),
         %Agent{} = agent <- Repo.get(Agent, agent_id),
         :ok <- ensure_not_banned(agent),
         :ok <-
           LocalKeypairVerifier.verify_reauth_signature(
             challenge.challenge,
             agent_id,
             agent.public_key,
             signature
           ) do
      token = session_token()
      now = now_utc()

      agent
      |> Agent.reauth_changeset(%{session_token: token, session_token_issued_at: now})
      |> Repo.update()
      |> case do
        {:ok, updated_agent} -> {:ok, %{agent_id: updated_agent.agent_id, session_token: token}}
        {:error, _changeset} -> {:error, :invalid_input}
      end
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def authenticate_session(agent_id, session_token)
      when is_binary(agent_id) and is_binary(session_token) do
    case Repo.get(Agent, agent_id) do
      nil ->
        {:error, :unauthorized}

      %Agent{} = agent ->
        cond do
          not is_nil(agent.banned_at) ->
            {:error, :forbidden}

          is_nil(agent.session_token) ->
            {:error, :unauthorized}

          not Regex.match?(@session_token_pattern, session_token) ->
            {:error, :unauthorized}

          agent.session_token != session_token ->
            {:error, :unauthorized}

          token_expired?(agent.session_token_issued_at) ->
            {:error, :unauthorized}

          true ->
            {:ok, agent}
        end
    end
  end

  def authenticate_session(_agent_id, _session_token), do: {:error, :unauthorized}

  def authorize_ws_join(agent_id, session_token)
      when is_binary(agent_id) and is_binary(session_token) do
    case Repo.get(Agent, agent_id) do
      nil ->
        {:error, :token_invalid}

      %Agent{} = agent ->
        cond do
          not is_nil(agent.banned_at) ->
            {:error, :banned}

          is_nil(agent.session_token) ->
            {:error, :token_revoked}

          not Regex.match?(@session_token_pattern, session_token) ->
            {:error, :token_invalid}

          agent.session_token != session_token ->
            {:error, :token_invalid}

          token_expired?(agent.session_token_issued_at) ->
            {:error, :token_revoked}

          true ->
            {:ok, agent}
        end
    end
  end

  def authorize_ws_join(_agent_id, _session_token), do: {:error, :token_invalid}

  defp consume_active_challenge(challenge_id, flow) do
    ensure_challenge_table!()
    now = now_utc()

    case :ets.take(@challenge_table, challenge_id) do
      [{^challenge_id, challenge}] ->
        if challenge.flow == flow and DateTime.compare(challenge.expires_at, now) == :gt do
          {:ok, challenge}
        else
          {:error, :signature_invalid}
        end

      [] ->
        {:error, :signature_invalid}
    end
  end

  defp validate_register_challenge(challenge, name, owner, public_key) do
    if challenge.name == name and challenge.owner == owner and challenge.public_key == public_key do
      :ok
    else
      {:error, :signature_invalid}
    end
  end

  defp validate_reauth_challenge(challenge, agent_id) do
    if challenge.agent_id == agent_id do
      :ok
    else
      {:error, :signature_invalid}
    end
  end

  defp ensure_not_banned(agent) do
    if is_nil(agent.banned_at), do: :ok, else: {:error, :banned}
  end

  defp now_utc do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end

  defp random_id(bytes) do
    :crypto.strong_rand_bytes(bytes)
    |> Base.encode16(case: :lower)
  end

  defp random_hex(bytes), do: random_id(bytes)

  defp session_token do
    random_hex(32)
  end

  defp token_expired?(nil), do: true

  defp token_expired?(issued_at) do
    ttl = Config.session_token_ttl_secs()
    DateTime.diff(now_utc(), issued_at, :second) > ttl
  end

  defp ensure_challenge_table! do
    case :ets.whereis(@challenge_table) do
      :undefined ->
        :ets.new(@challenge_table, [:named_table, :set, :public, read_concurrency: true])
        :ok

      _tid ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end

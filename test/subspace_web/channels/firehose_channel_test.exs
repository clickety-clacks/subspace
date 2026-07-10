defmodule SubspaceWeb.FirehoseChannelTest do
  use Subspace.DataCase, async: false

  import Phoenix.ChannelTest

  alias Subspace.Agents.Agent
  alias Subspace.Identity.Config
  alias Subspace.MessageBuffer
  alias Subspace.RateLimit.Store
  alias Subspace.Repo
  alias SubspaceWeb.FirehoseSocket

  @endpoint SubspaceWeb.Endpoint

  setup do
    MessageBuffer.clear()
    :ets.delete_all_objects(Store.table_name())

    agent =
      Repo.insert!(%Agent{
        agent_id: "agent-#{System.unique_integer([:positive])}",
        public_key: "agent-public-key",
        name: "sender",
        owner: "flynn",
        session_token: String.duplicate("a", 64),
        session_token_issued_at: DateTime.utc_now()
      })

    {:ok, socket} = connect(FirehoseSocket, %{})

    %{agent: agent, socket: socket}
  end

  test "broadcasts sender embeddings on live messages", %{agent: agent, socket: socket} do
    agent_id = agent.agent_id

    {:ok, _reply, socket} =
      subscribe_and_join(socket, "firehose", %{
        "agent_id" => agent_id,
        "session_token" => agent.session_token
      })

    assert_push "server_hello", %{type: "server_hello"}

    embeddings = [%{"space_id" => "test:space", "vector" => [0.25, 0.75]}]

    ref =
      push(socket, "post_message", %{
        "text" => "wake target",
        "embeddings" => embeddings
      })

    assert_reply ref, :ok, %{id: msg_id}

    assert_broadcast "new_message", payload
    assert payload.id == msg_id
    assert payload.agentId == agent_id
    assert payload.agentName == "sender"
    assert payload.text == "wake target"
    assert is_binary(payload.ts)
    assert payload.supplied_embeddings == embeddings
    refute Map.has_key?(payload, :embeddings)

    assert json_payload(payload)["supplied_embeddings"] == embeddings
    refute Map.has_key?(json_payload(payload), "embeddings")

    assert [%{id: ^msg_id, embeddings: ^embeddings}] = MessageBuffer.recent()
  end

  test "replays posted messages with sender embeddings", %{agent: agent, socket: socket} do
    agent_id = agent.agent_id
    embeddings = [%{"space_id" => "test:space", "vector" => [1.0, 0.0]}]

    {:ok, _reply, socket} =
      subscribe_and_join(socket, "firehose", %{
        "agent_id" => agent_id,
        "session_token" => agent.session_token
      })

    assert_push "server_hello", %{type: "server_hello"}

    ref =
      push(socket, "post_message", %{
        "text" => "wake target",
        "embeddings" => embeddings
      })

    assert_reply ref, :ok, %{id: msg_id}
    assert_broadcast "new_message", %{id: ^msg_id}

    {:ok, replay_socket} = connect(FirehoseSocket, %{})

    {:ok, _reply, _socket} =
      subscribe_and_join(replay_socket, "firehose", %{
        "agent_id" => agent_id,
        "session_token" => agent.session_token
      })

    assert_push "server_hello", %{type: "server_hello"}

    assert_push "replay_message", replay_payload
    assert replay_payload.id == msg_id
    assert replay_payload.agentId == agent_id
    assert replay_payload.agentName == "sender"
    assert replay_payload.text == "wake target"
    assert is_binary(replay_payload.ts)
    assert replay_payload.supplied_embeddings == embeddings
    refute Map.has_key?(replay_payload, :embeddings)

    assert json_payload(replay_payload)["supplied_embeddings"] == embeddings
    refute Map.has_key?(json_payload(replay_payload), "embeddings")
  end

  test "trusted session age bypass preserves exact channel auth errors", %{
    agent: agent,
    socket: socket
  } do
    identity_config = Application.get_env(:subspace, :identity, [])

    Application.put_env(
      :subspace,
      :identity,
      Keyword.put(identity_config, :trusted_machine_agent_ids, [agent.agent_id])
    )

    on_exit(fn -> Application.put_env(:subspace, :identity, identity_config) end)

    old_issued_at =
      DateTime.add(DateTime.utc_now(), -Config.session_token_ttl_secs() - 1, :second)

    agent =
      agent
      |> Ecto.Changeset.change(session_token_issued_at: old_issued_at)
      |> Repo.update!()

    assert {:ok, _reply, _socket} =
             subscribe_and_join(socket, "firehose", %{
               "agent_id" => agent.agent_id,
               "session_token" => agent.session_token
             })

    assert_push "server_hello", %{type: "server_hello"}

    {:ok, malformed_socket} = connect(FirehoseSocket, %{})

    assert {:error, %{error: "TOKEN_INVALID"}} =
             subscribe_and_join(malformed_socket, "firehose", %{
               "agent_id" => agent.agent_id,
               "session_token" => "malformed"
             })

    agent
    |> Ecto.Changeset.change(session_token: nil)
    |> Repo.update!()

    {:ok, revoked_socket} = connect(FirehoseSocket, %{})

    assert {:error, %{error: "TOKEN_REVOKED"}} =
             subscribe_and_join(revoked_socket, "firehose", %{
               "agent_id" => agent.agent_id,
               "session_token" => agent.session_token
             })

    agent
    |> Ecto.Changeset.change(banned_at: DateTime.utc_now())
    |> Repo.update!()

    {:ok, banned_socket} = connect(FirehoseSocket, %{})

    assert {:error, %{error: "BANNED"}} =
             subscribe_and_join(banned_socket, "firehose", %{
               "agent_id" => agent.agent_id,
               "session_token" => agent.session_token
             })
  end

  defp json_payload(payload) do
    payload
    |> Jason.encode!()
    |> Jason.decode!()
  end
end

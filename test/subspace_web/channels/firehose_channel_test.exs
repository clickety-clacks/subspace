defmodule SubspaceWeb.FirehoseChannelTest do
  use Subspace.DataCase, async: false

  import Phoenix.ChannelTest

  alias Subspace.Agents.Agent
  alias Subspace.MessageBuffer
  alias Subspace.RateLimit.Store
  alias Subspace.Repo
  alias SubspaceWeb.FirehoseSocket

  @endpoint SubspaceWeb.Endpoint

  setup do
    original_limit = Application.get_env(:subspace, :buffer_max_messages)

    Application.put_env(:subspace, :buffer_max_messages, 200)
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

    on_exit(fn ->
      restore_limit(original_limit)
      MessageBuffer.clear()
    end)

    %{agent: agent, socket: socket}
  end

  test "broadcasts sender embeddings and seq on live messages", %{agent: agent, socket: socket} do
    {:ok, _reply, socket} = join_firehose(socket, agent)
    assert_push "server_hello", %{type: "server_hello"}
    assert_push "replay_done", %{type: "replay_done", tail_seq: 1, head_seq: 0}

    embeddings = [%{"space_id" => "test:space", "vector" => [0.25, 0.75]}]

    ref =
      push(socket, "post_message", %{
        "text" => "wake target",
        "embeddings" => embeddings
      })

    assert_reply ref, :ok, %{id: msg_id}

    assert_broadcast "new_message", payload
    assert payload.seq == 1
    assert payload.id == msg_id
    assert payload.agentId == agent.agent_id
    assert payload.agentName == "sender"
    assert payload.text == "wake target"
    assert is_binary(payload.ts)
    assert payload.supplied_embeddings == embeddings
    refute Map.has_key?(payload, :embeddings)

    assert json_payload(payload)["supplied_embeddings"] == embeddings
    refute Map.has_key?(json_payload(payload), "embeddings")

    assert [%{seq: 1, id: ^msg_id, embeddings: ^embeddings}] = MessageBuffer.recent()
  end

  test "no-cursor join replays current window with seq and replay_done", %{agent: agent} do
    {:ok, %{seq: first_seq, id: first_id}} = buffer_message("msg-1", agent.agent_id, "first")
    {:ok, %{seq: second_seq, id: second_id}} = buffer_message("msg-2", agent.agent_id, "second")

    {:ok, replay_socket} = connect(FirehoseSocket, %{})
    {:ok, _reply, _socket} = join_firehose(replay_socket, agent)

    assert_push "server_hello", %{type: "server_hello"}

    assert_push "replay_message", first_payload
    assert first_payload.seq == first_seq
    assert first_payload.id == first_id
    assert first_payload.agentId == agent.agent_id
    assert first_payload.agentName == "sender"
    assert first_payload.text == "first"
    assert is_binary(first_payload.ts)
    assert first_payload.supplied_embeddings == []
    refute Map.has_key?(first_payload, :embeddings)

    assert_push "replay_message", %{seq: ^second_seq, id: ^second_id, text: "second"}
    assert_push "replay_done", %{type: "replay_done", tail_seq: 1, head_seq: 2}
    refute_channel_push("replay_gap")
  end

  test "cursor join with replay_after_seq replays only newer messages", %{agent: agent} do
    {:ok, %{seq: first_seq}} = buffer_message("msg-1", agent.agent_id, "first")
    {:ok, %{seq: second_seq}} = buffer_message("msg-2", agent.agent_id, "second")
    {:ok, %{seq: third_seq}} = buffer_message("msg-3", agent.agent_id, "third")

    {:ok, replay_socket} = connect(FirehoseSocket, %{})

    {:ok, _reply, _socket} =
      join_firehose(replay_socket, agent, %{"replay_after_seq" => first_seq})

    assert_push "server_hello", %{type: "server_hello"}
    assert_push "replay_message", %{seq: ^second_seq, text: "second"}
    assert_push "replay_message", %{seq: ^third_seq, text: "third"}
    assert_push "replay_done", %{tail_seq: 1, head_seq: 3}
    refute_channel_push("replay_message")
  end

  test "last_seq alias and equal aliases are accepted", %{agent: agent} do
    {:ok, %{seq: first_seq}} = buffer_message("msg-1", agent.agent_id, "first")
    {:ok, %{seq: second_seq}} = buffer_message("msg-2", agent.agent_id, "second")

    {:ok, alias_socket} = connect(FirehoseSocket, %{})
    {:ok, _reply, _socket} = join_firehose(alias_socket, agent, %{"last_seq" => first_seq})

    assert_push "server_hello", %{type: "server_hello"}
    assert_push "replay_message", %{seq: ^second_seq}
    assert_push "replay_done", %{tail_seq: 1, head_seq: 2}

    {:ok, equal_socket} = connect(FirehoseSocket, %{})

    {:ok, _reply, _socket} =
      join_firehose(equal_socket, agent, %{
        "replay_after_seq" => first_seq,
        "last_seq" => first_seq
      })

    assert_push "server_hello", %{type: "server_hello"}
    assert_push "replay_message", %{seq: ^second_seq}
    assert_push "replay_done", %{tail_seq: 1, head_seq: 2}
  end

  test "invalid cursor join payloads return INVALID_CURSOR", %{agent: agent, socket: socket} do
    assert {:error, %{error: "INVALID_CURSOR"}} =
             join_firehose(socket, agent, %{"replay_after_seq" => 1, "last_seq" => 2})

    {:ok, socket} = connect(FirehoseSocket, %{})

    assert {:error, %{error: "INVALID_CURSOR"}} =
             join_firehose(socket, agent, %{"replay_after_seq" => -1})

    {:ok, socket} = connect(FirehoseSocket, %{})

    assert {:error, %{error: "INVALID_CURSOR"}} =
             join_firehose(socket, agent, %{"last_seq" => "1"})
  end

  test "stale cursor after rollover pushes gap then retained messages and replay_done", %{
    agent: agent
  } do
    Application.put_env(:subspace, :buffer_max_messages, 2)

    buffer_message("msg-1", agent.agent_id, "first")
    {:ok, %{seq: second_seq}} = buffer_message("msg-2", agent.agent_id, "second")
    {:ok, %{seq: third_seq}} = buffer_message("msg-3", agent.agent_id, "third")

    {:ok, replay_socket} = connect(FirehoseSocket, %{})
    {:ok, _reply, _socket} = join_firehose(replay_socket, agent, %{"replay_after_seq" => 0})

    assert_push "server_hello", %{type: "server_hello"}
    assert_push "replay_gap", %{type: "replay_gap", requested_seq: 0, tail_seq: 2, head_seq: 3}
    assert_push "replay_message", %{seq: ^second_seq, text: "second"}
    assert_push "replay_message", %{seq: ^third_seq, text: "third"}
    assert_push "replay_done", %{type: "replay_done", tail_seq: 2, head_seq: 3}
  end

  test "future cursor against non-empty buffer pushes gap and retained messages", %{agent: agent} do
    {:ok, %{seq: first_seq}} = buffer_message("msg-1", agent.agent_id, "first")
    {:ok, %{seq: second_seq}} = buffer_message("msg-2", agent.agent_id, "second")

    {:ok, replay_socket} = connect(FirehoseSocket, %{})
    {:ok, _reply, _socket} = join_firehose(replay_socket, agent, %{"replay_after_seq" => 50})

    assert_push "server_hello", %{type: "server_hello"}
    assert_push "replay_gap", %{type: "replay_gap", requested_seq: 50, tail_seq: 1, head_seq: 2}
    assert_push "replay_message", %{seq: ^first_seq, text: "first"}
    assert_push "replay_message", %{seq: ^second_seq, text: "second"}
    assert_push "replay_done", %{type: "replay_done", tail_seq: 1, head_seq: 2}
  end

  test "replay_done bounds cover empty, partial, and rolled-over buffers", %{agent: agent} do
    {:ok, empty_socket} = connect(FirehoseSocket, %{})
    {:ok, _reply, _socket} = join_firehose(empty_socket, agent)
    assert_push "server_hello", %{type: "server_hello"}
    assert_push "replay_done", %{tail_seq: 1, head_seq: 0}

    buffer_message("msg-1", agent.agent_id, "first")

    {:ok, partial_socket} = connect(FirehoseSocket, %{})
    {:ok, _reply, _socket} = join_firehose(partial_socket, agent)
    assert_push "server_hello", %{type: "server_hello"}
    assert_push "replay_message", %{seq: 1}
    assert_push "replay_done", %{tail_seq: 1, head_seq: 1}

    Application.put_env(:subspace, :buffer_max_messages, 1)
    buffer_message("msg-2", agent.agent_id, "second")

    {:ok, rolled_socket} = connect(FirehoseSocket, %{})
    {:ok, _reply, _socket} = join_firehose(rolled_socket, agent)
    assert_push "server_hello", %{type: "server_hello"}
    assert_push "replay_message", %{seq: 2}
    assert_push "replay_done", %{tail_seq: 2, head_seq: 2}
    refute_channel_push("replay_gap")
  end

  defp join_firehose(socket, agent, payload \\ %{}) do
    subscribe_and_join(
      socket,
      "firehose",
      Map.merge(
        %{
          "agent_id" => agent.agent_id,
          "session_token" => agent.session_token
        },
        payload
      )
    )
  end

  defp buffer_message(id, agent_id, text) do
    MessageBuffer.insert(id, agent_id, "sender", text, DateTime.utc_now(), [])
  end

  defp json_payload(payload) do
    payload
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp refute_channel_push(event) do
    refute_receive %Phoenix.Socket.Message{event: ^event}, 50
  end

  defp restore_limit(nil), do: Application.delete_env(:subspace, :buffer_max_messages)
  defp restore_limit(limit), do: Application.put_env(:subspace, :buffer_max_messages, limit)
end

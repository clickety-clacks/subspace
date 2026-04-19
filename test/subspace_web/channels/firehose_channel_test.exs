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

    assert_broadcast "new_message", %{
      id: ^msg_id,
      agentId: ^agent_id,
      agentName: "sender",
      text: "wake target",
      supplied_embeddings: ^embeddings
    }

    assert [%{id: ^msg_id, embeddings: ^embeddings}] = MessageBuffer.recent()
  end

  test "replays buffered messages with sender embeddings", %{agent: agent, socket: socket} do
    agent_id = agent.agent_id
    ts = DateTime.utc_now()
    embeddings = [%{"space_id" => "test:space", "vector" => [1.0, 0.0]}]

    {:ok, _message} =
      MessageBuffer.insert("msg-1", agent_id, "sender", "wake target", ts, embeddings)

    {:ok, _reply, _socket} =
      subscribe_and_join(socket, "firehose", %{
        "agent_id" => agent_id,
        "session_token" => agent.session_token
      })

    assert_push "server_hello", %{type: "server_hello"}

    assert_push "replay_message", %{
      id: "msg-1",
      agentId: ^agent_id,
      agentName: "sender",
      text: "wake target",
      ts: replay_ts,
      supplied_embeddings: ^embeddings
    }

    assert replay_ts == DateTime.to_iso8601(ts)
  end
end

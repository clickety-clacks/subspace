defmodule Subspace.MessageBufferTest do
  use ExUnit.Case, async: false

  alias Subspace.MessageBuffer

  setup do
    MessageBuffer.clear()
    :ok
  end

  test "stores agent names and embeddings for replay" do
    ts = DateTime.utc_now()
    embeddings = [%{"space_id" => "test:space", "vector" => [1.0, 0.0]}]

    assert {:ok,
            %{
              id: "msg-1",
              agent_id: "agent-1",
              agent_name: "sender",
              text: "wake target",
              ts: ^ts,
              embeddings: ^embeddings
            }} = MessageBuffer.insert("msg-1", "agent-1", "sender", "wake target", ts, embeddings)

    assert [
             %{
               id: "msg-1",
               agent_id: "agent-1",
               agent_name: "sender",
               text: "wake target",
               ts: ^ts,
               embeddings: ^embeddings
             }
           ] = MessageBuffer.recent()
  end
end

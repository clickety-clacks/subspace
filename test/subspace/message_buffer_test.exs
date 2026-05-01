defmodule Subspace.MessageBufferTest do
  use ExUnit.Case, async: false

  alias Subspace.MessageBuffer

  setup do
    original_limit = Application.get_env(:subspace, :buffer_max_messages)

    MessageBuffer.clear()

    on_exit(fn ->
      restore_limit(original_limit)
      MessageBuffer.clear()
    end)

    :ok
  end

  test "insert assigns monotonic seq and preserves embeddings" do
    ts = DateTime.utc_now()
    embeddings = [%{"space_id" => "test:space", "vector" => [1.0, 0.0]}]

    assert {:ok, %{seq: 1, id: "msg-1", embeddings: ^embeddings}} =
             MessageBuffer.insert("msg-1", "agent-1", "sender", "wake target", ts, embeddings)

    assert {:ok, %{seq: 2, id: "msg-2"}} =
             MessageBuffer.insert("msg-2", "agent-1", "sender", "next", ts, [])

    assert [
             %{seq: 1, id: "msg-1", embeddings: ^embeddings},
             %{seq: 2, id: "msg-2", embeddings: []}
           ] = MessageBuffer.recent()
  end

  test "clear resets sequence state" do
    insert!("msg-1")
    assert :ok = MessageBuffer.clear()
    assert %{head_seq: 0, tail_seq: 1} = MessageBuffer.bounds()
    assert {:ok, %{seq: 1}} = insert!("msg-2")
  end

  test "recent orders by ascending seq while keeping timestamp filter and limit semantics" do
    old_ts = ~U[2026-01-01 00:00:00Z]
    middle_ts = ~U[2026-01-02 00:00:00Z]
    new_ts = ~U[2026-01-03 00:00:00Z]

    insert!("msg-1", old_ts)
    insert!("msg-2", new_ts)
    insert!("msg-3", middle_ts)

    assert Enum.map(MessageBuffer.recent(), & &1.id) == ["msg-1", "msg-2", "msg-3"]

    assert Enum.map(MessageBuffer.recent(old_ts, 10), & &1.id) == ["msg-2", "msg-3"]
    assert Enum.map(MessageBuffer.recent(nil, 2), & &1.id) == ["msg-2", "msg-3"]
  end

  test "replay_after returns only retained messages newer than cursor" do
    insert!("msg-1")
    insert!("msg-2")
    insert!("msg-3")

    assert {:ok, messages, %{tail_seq: 1, head_seq: 3}} = MessageBuffer.replay_after(1)
    assert Enum.map(messages, & &1.seq) == [2, 3]

    assert {:ok, [], %{tail_seq: 1, head_seq: 3}} = MessageBuffer.replay_after(3)
  end

  test "recent_with_bounds returns replay window and bounds from one buffer state" do
    insert!("msg-1")
    insert!("msg-2")

    assert {messages, %{tail_seq: 1, head_seq: 2}} = MessageBuffer.recent_with_bounds()
    assert Enum.map(messages, & &1.seq) == [1, 2]
  end

  test "fresh empty replay is ok for any non-negative cursor" do
    assert {:ok, [], %{tail_seq: 1, head_seq: 0}} = MessageBuffer.replay_after(0)
    assert {:ok, [], %{tail_seq: 1, head_seq: 0}} = MessageBuffer.replay_after(5_000)
  end

  test "rollover advances tail_seq and reports stale cursor gaps" do
    Application.put_env(:subspace, :buffer_max_messages, 2)

    insert!("msg-1")
    insert!("msg-2")
    insert!("msg-3")

    assert %{tail_seq: 2, head_seq: 3} = MessageBuffer.bounds()
    assert Enum.map(MessageBuffer.recent(), & &1.seq) == [2, 3]

    assert {:gap, messages, %{requested_seq: 0, tail_seq: 2, head_seq: 3}} =
             MessageBuffer.replay_after(0)

    assert Enum.map(messages, & &1.seq) == [2, 3]
  end

  test "cursor exactly before retained tail is not a gap" do
    Application.put_env(:subspace, :buffer_max_messages, 2)

    insert!("msg-1")
    insert!("msg-2")
    insert!("msg-3")

    assert {:ok, messages, %{tail_seq: 2, head_seq: 3}} = MessageBuffer.replay_after(1)
    assert Enum.map(messages, & &1.seq) == [2, 3]
  end

  test "future cursor against non-empty buffer reports gap and replays retained messages" do
    insert!("msg-1")
    insert!("msg-2")

    assert {:gap, messages, %{requested_seq: 50, tail_seq: 1, head_seq: 2}} =
             MessageBuffer.replay_after(50)

    assert Enum.map(messages, & &1.seq) == [1, 2]
  end

  test "empty buffer after internal trim reports gap for stale cursor" do
    insert!("msg-1")
    assert {1, nil} = MessageBuffer.trim_to_limit(0)
    assert %{tail_seq: 2, head_seq: 1} = MessageBuffer.bounds()

    assert {:gap, [], %{requested_seq: 0, tail_seq: 2, head_seq: 1}} =
             MessageBuffer.replay_after(0)
  end

  defp insert!(id, ts \\ DateTime.utc_now()) do
    MessageBuffer.insert(id, "agent-1", "sender", "wake target", ts, [])
  end

  defp restore_limit(nil), do: Application.delete_env(:subspace, :buffer_max_messages)
  defp restore_limit(limit), do: Application.put_env(:subspace, :buffer_max_messages, limit)
end

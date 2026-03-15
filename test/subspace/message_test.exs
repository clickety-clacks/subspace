defmodule Subspace.MessageBufferTest do
  use ExUnit.Case, async: false

  alias Subspace.MessageBuffer

  setup do
    previous_buffer_limit = Application.get_env(:subspace, :buffer_max_messages)
    MessageBuffer.clear()

    on_exit(fn ->
      restore_optional_env(:buffer_max_messages, previous_buffer_limit)
      MessageBuffer.clear()
    end)

    :ok
  end

  test "trim_to_limit/1 deletes the oldest rows beyond the limit" do
    base = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _message} =
             MessageBuffer.insert(Ecto.UUID.generate(), "agent-1", "first", base)

    assert {:ok, _message} =
             MessageBuffer.insert(
               Ecto.UUID.generate(),
               "agent-1",
               "second",
               DateTime.add(base, 1, :microsecond)
             )

    assert {:ok, _message} =
             MessageBuffer.insert(
               Ecto.UUID.generate(),
               "agent-1",
               "third",
               DateTime.add(base, 2, :microsecond)
             )

    assert {1, nil} = MessageBuffer.trim_to_limit(2)

    messages = MessageBuffer.recent(nil, 10)

    assert Enum.map(messages, & &1.text) == ["second", "third"]
    assert length(messages) == 2
  end

  test "buffer_limit/0 reads application config and insert/4 trims to that limit" do
    Application.put_env(:subspace, :buffer_max_messages, 2)

    base = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert MessageBuffer.buffer_limit() == 2

    assert {:ok, _message} =
             MessageBuffer.insert(Ecto.UUID.generate(), "agent-2", "first", base)

    assert {:ok, _message} =
             MessageBuffer.insert(
               Ecto.UUID.generate(),
               "agent-2",
               "second",
               DateTime.add(base, 1, :microsecond)
             )

    assert {:ok, _message} =
             MessageBuffer.insert(
               Ecto.UUID.generate(),
               "agent-2",
               "third",
               DateTime.add(base, 2, :microsecond)
             )

    messages = MessageBuffer.recent(nil, 10)

    assert Enum.map(messages, & &1.text) == ["second", "third"]
    assert length(messages) == 2
  end

  defp restore_optional_env(key, nil), do: Application.delete_env(:subspace, key)
  defp restore_optional_env(key, value), do: Application.put_env(:subspace, key, value)
end

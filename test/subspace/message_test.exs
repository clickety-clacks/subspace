defmodule Subspace.MessageTest do
  use Subspace.DataCase, async: false

  alias Subspace.Message
  alias Subspace.Repo

  test "trim_to_limit/1 deletes the oldest rows beyond the limit" do
    base = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _message} =
             Message.insert(Ecto.UUID.generate(), "agent-1", "first", base)

    assert {:ok, _message} =
             Message.insert(
               Ecto.UUID.generate(),
               "agent-1",
               "second",
               DateTime.add(base, 1, :microsecond)
             )

    assert {:ok, _message} =
             Message.insert(
               Ecto.UUID.generate(),
               "agent-1",
               "third",
               DateTime.add(base, 2, :microsecond)
             )

    assert {1, nil} = Message.trim_to_limit(2)

    messages = Message.recent(nil, 10)

    assert Enum.map(messages, & &1.text) == ["second", "third"]
    assert Repo.aggregate(Message, :count, :id) == 2
  end
end

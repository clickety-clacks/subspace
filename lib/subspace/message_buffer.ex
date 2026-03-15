defmodule Subspace.MessageBuffer do
  @moduledoc false

  use GenServer

  @table :subspace_message_buffer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def insert(id, agent_id, text, ts)
      when is_binary(id) and is_binary(agent_id) and is_binary(text) and is_struct(ts, DateTime) do
    GenServer.call(__MODULE__, {:insert, {id, agent_id, text, ts}})
  end

  def recent(since \\ nil, limit \\ nil)

  def recent(since, nil), do: recent(since, buffer_limit())

  def recent(since, limit) when is_integer(limit) and limit >= 0 do
    GenServer.call(__MODULE__, {:recent, since, limit})
  end

  def trim_to_limit(limit) when is_integer(limit) and limit >= 0 do
    GenServer.call(__MODULE__, {:trim_to_limit, limit})
  end

  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  def buffer_limit, do: Application.get_env(:subspace, :buffer_max_messages, 200)

  def table_name, do: @table

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{table: table, order: []}}
  end

  @impl true
  def handle_call({:insert, {id, _agent_id, _text, ts} = tuple}, _from, state) do
    true = :ets.insert(@table, tuple)
    state = %{state | order: insert_order(state.order, {ts, id})}
    {_trimmed, state} = trim_order(state, buffer_limit())

    {:reply, {:ok, message_from_tuple(tuple)}, state}
  end

  def handle_call({:recent, since, limit}, _from, state) do
    messages =
      state.order
      |> Enum.reduce([], fn {_ts, id}, acc ->
        case :ets.lookup(@table, id) do
          [{^id, agent_id, text, ts}] ->
            if include_message?(ts, since) do
              [%{id: id, agent_id: agent_id, text: text, ts: ts} | acc]
            else
              acc
            end

          [] ->
            acc
        end
      end)
      |> Enum.reverse()
      |> limit_recent(limit)

    {:reply, messages, state}
  end

  def handle_call({:trim_to_limit, limit}, _from, state) do
    {trimmed, state} = trim_order(state, limit)
    {:reply, {trimmed, nil}, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | order: []}}
  end

  defp insert_order([], entry), do: [entry]

  defp insert_order(order, {ts, id} = entry) do
    {left, right} =
      Enum.split_while(order, fn {existing_ts, existing_id} ->
        DateTime.compare(existing_ts, ts) != :gt and
          not (DateTime.compare(existing_ts, ts) == :eq and existing_id > id)
      end)

    left ++ [entry | right]
  end

  defp trim_order(state, limit) do
    excess = max(length(state.order) - limit, 0)
    {to_drop, keep} = Enum.split(state.order, excess)

    Enum.each(to_drop, fn {_ts, id} ->
      :ets.delete(@table, id)
    end)

    {length(to_drop), %{state | order: keep}}
  end

  defp include_message?(_ts, nil), do: true
  defp include_message?(ts, since), do: DateTime.compare(ts, since) == :gt

  defp limit_recent(messages, limit) do
    count = length(messages)

    if count <= limit do
      messages
    else
      Enum.drop(messages, count - limit)
    end
  end

  defp message_from_tuple({id, agent_id, text, ts}) do
    %{id: id, agent_id: agent_id, text: text, ts: ts}
  end
end

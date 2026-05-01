defmodule Subspace.MessageBuffer do
  @moduledoc false

  use GenServer

  @table :subspace_message_buffer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def insert(id, agent_id, agent_name, text, ts, embeddings \\ [])
      when is_binary(id) and is_binary(agent_id) and is_binary(agent_name) and is_binary(text) and
             is_struct(ts, DateTime) and is_list(embeddings) do
    GenServer.call(__MODULE__, {:insert, {id, agent_id, agent_name, text, ts, embeddings}})
  end

  def recent(since \\ nil, limit \\ nil)

  def recent(since, nil), do: recent(since, buffer_limit())

  def recent(since, limit) when is_integer(limit) and limit >= 0 do
    GenServer.call(__MODULE__, {:recent, since, limit})
  end

  def recent_with_bounds do
    GenServer.call(__MODULE__, :recent_with_bounds)
  end

  def replay_after(seq) when is_integer(seq) and seq >= 0 do
    GenServer.call(__MODULE__, {:replay_after, seq})
  end

  def bounds do
    GenServer.call(__MODULE__, :bounds)
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
    {:ok, %{table: table, order: [], head_seq: 0, tail_seq: 1}}
  end

  @impl true
  def handle_call(
        {:insert, {id, agent_id, agent_name, text, ts, embeddings}},
        _from,
        state
      ) do
    seq = state.head_seq + 1
    tuple = {id, seq, agent_id, agent_name, text, ts, embeddings}
    true = :ets.insert(@table, tuple)

    state = %{state | order: state.order ++ [{seq, id}], head_seq: seq}
    {_trimmed, state} = trim_order(state, buffer_limit())

    {:reply, {:ok, message_from_tuple(tuple)}, state}
  end

  def handle_call({:recent, since, limit}, _from, state) do
    messages = recent_messages(state, since, limit)

    {:reply, messages, state}
  end

  def handle_call(:recent_with_bounds, _from, state) do
    {:reply, {recent_messages(state, nil, buffer_limit()), bounds_from_state(state)}, state}
  end

  def handle_call({:replay_after, seq}, _from, state) do
    bounds = bounds_from_state(state)
    messages = messages_after(state, seq)

    cond do
      state.head_seq == 0 and state.order == [] ->
        {:reply, {:ok, [], bounds}, state}

      state.order == [] and seq < state.head_seq ->
        {:reply, {:gap, [], Map.put(bounds, :requested_seq, seq)}, state}

      state.order != [] and (seq > state.head_seq or seq < state.tail_seq - 1) ->
        {:reply, {:gap, messages_after(state, 0), Map.put(bounds, :requested_seq, seq)}, state}

      true ->
        {:reply, {:ok, messages, bounds}, state}
    end
  end

  def handle_call(:bounds, _from, state) do
    {:reply, bounds_from_state(state), state}
  end

  def handle_call({:trim_to_limit, limit}, _from, state) do
    {trimmed, state} = trim_order(state, limit)
    {:reply, {trimmed, nil}, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | order: [], head_seq: 0, tail_seq: 1}}
  end

  defp trim_order(state, limit) do
    excess = max(length(state.order) - limit, 0)
    {to_drop, keep} = Enum.split(state.order, excess)

    Enum.each(to_drop, fn {_seq, id} ->
      :ets.delete(@table, id)
    end)

    state = %{state | order: keep, tail_seq: tail_seq(state.head_seq, keep)}

    {length(to_drop), state}
  end

  defp include_message?(_ts, nil), do: true
  defp include_message?(ts, since), do: DateTime.compare(ts, since) == :gt

  defp recent_messages(state, since, limit) do
    state.order
    |> Enum.reduce([], fn {_seq, id}, acc ->
      case :ets.lookup(@table, id) do
        [{^id, seq, agent_id, agent_name, text, ts, embeddings}] ->
          if include_message?(ts, since) do
            [
              %{
                seq: seq,
                id: id,
                agent_id: agent_id,
                agent_name: agent_name,
                text: text,
                ts: ts,
                embeddings: embeddings
              }
              | acc
            ]
          else
            acc
          end

        [] ->
          acc
      end
    end)
    |> Enum.reverse()
    |> limit_recent(limit)
  end

  defp limit_recent(messages, limit) do
    count = length(messages)

    if count <= limit do
      messages
    else
      Enum.drop(messages, count - limit)
    end
  end

  defp messages_after(state, seq) do
    state.order
    |> Enum.filter(fn {message_seq, _id} -> message_seq > seq end)
    |> Enum.flat_map(fn {_message_seq, id} ->
      case :ets.lookup(@table, id) do
        [tuple] -> [message_from_tuple(tuple)]
        [] -> []
      end
    end)
  end

  defp bounds_from_state(state), do: %{tail_seq: state.tail_seq, head_seq: state.head_seq}

  defp tail_seq(head_seq, []), do: head_seq + 1
  defp tail_seq(_head_seq, [{seq, _id} | _rest]), do: seq

  defp message_from_tuple({id, seq, agent_id, agent_name, text, ts, embeddings}) do
    %{
      seq: seq,
      id: id,
      agent_id: agent_id,
      agent_name: agent_name,
      text: text,
      ts: ts,
      embeddings: embeddings
    }
  end
end

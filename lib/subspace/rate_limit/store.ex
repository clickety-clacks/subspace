defmodule Subspace.RateLimit.Store do
  @moduledoc """
  GenServer that owns the ETS table for rate limit buckets.
  """

  use GenServer

  alias Subspace.RateLimit.TokenBucket

  @table :subspace_rate_limits

  # Bucket configurations: {capacity, refill_per_sec}
  # :register - 10 per hour per IP
  # :post_message - 60 per minute per agent (REST, reserved for future)
  # :ws_post_message - 60 per minute per agent

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Attempts to consume a token for the given scope and subject.
  Returns :ok on success.
  Returns {:error, retry_after_secs} when rate limited.
  """
  def check_rate_limit(scope, subject) when is_atom(scope) and is_binary(subject) do
    key = {scope, subject}
    {capacity, refill_per_sec} = bucket_config(scope)
    now_mono = :erlang.monotonic_time(:millisecond)

    bucket =
      case :ets.lookup(@table, key) do
        [{^key, existing}] -> existing
        [] -> TokenBucket.new(capacity, refill_per_sec)
      end

    case TokenBucket.consume(bucket, now_mono) do
      {:ok, updated} ->
        :ets.insert(@table, {key, updated})
        :ok

      {:error, retry_after, updated} ->
        :ets.insert(@table, {key, updated})
        {:error, retry_after}
    end
  end

  @doc """
  Removes all buckets that have been idle for longer than the given milliseconds.
  Called by Cleanup process.
  """
  def cleanup_idle(idle_ms) do
    now_mono = :erlang.monotonic_time(:millisecond)

    :ets.foldl(
      fn {key, bucket}, count ->
        if TokenBucket.idle_for?(bucket, idle_ms, now_mono) do
          :ets.delete(@table, key)
          count + 1
        else
          count
        end
      end,
      0,
      @table
    )
  end

  @doc """
  Returns the ETS table name for testing purposes.
  """
  def table_name, do: @table

  # GenServer callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call(:table_info, _from, state) do
    {:reply, :ets.info(@table), state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private

  defp bucket_config(:register) do
    # 10 per hour = 10 capacity, refill at 10/3600 per second
    capacity = Application.get_env(:subspace, :rate_limit_register_per_hour, 10)
    {capacity, capacity / 3600.0}
  end

  defp bucket_config(:post_message) do
    # 60 per minute = 60 capacity, refill at 1 per second
    capacity = Application.get_env(:subspace, :rate_limit_messages_per_min, 60)
    {capacity, capacity / 60.0}
  end

  defp bucket_config(:ws_post_message) do
    # 60 per minute = 60 capacity, refill at 1 per second
    capacity = Application.get_env(:subspace, :rate_limit_ws_messages_per_min, 60)
    {capacity, capacity / 60.0}
  end

  defp bucket_config(_unknown) do
    # Default fallback: 100 per minute
    {100, 100 / 60.0}
  end
end

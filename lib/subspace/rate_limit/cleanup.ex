defmodule Subspace.RateLimit.Cleanup do
  @moduledoc """
  Periodic cleanup process for stale rate limit buckets.
  Runs every 5 minutes and removes buckets idle > 2 hours.
  """

  use GenServer

  alias Subspace.RateLimit.Store

  @cleanup_interval_ms 5 * 60 * 1000
  @idle_threshold_ms 2 * 60 * 60 * 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    Store.cleanup_idle(@idle_threshold_ms)
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end

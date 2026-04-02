defmodule Subspace.SchemaPreflight do
  @moduledoc """
  Boot-time check that the agents table exists and is accessible.

  This module runs as a temporary Task in the supervision tree, placed
  immediately after Subspace.Repo. If the agents table is missing or
  inaccessible, it logs a clear, actionable error message and halts the
  VM — preventing the server from silently serving broken traffic.
  """

  require Logger

  def start_link(_opts) do
    Task.start_link(&run/0)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  defp run do
    case Ecto.Adapters.SQL.query(Subspace.Repo, "SELECT 1 FROM agents LIMIT 1", []) do
      {:ok, _} ->
        Logger.info("[Subspace] Schema preflight passed — agents table is accessible")

      {:error, %{postgres: %{code: :undefined_table}}} ->
        Logger.error("""
        [Subspace] STARTUP FAILED — agents table does not exist.

        The database schema is missing. Run migrations before starting the server:

            mix ecto.migrate

        Or, for a fresh install:

            mix ecto.setup

        The application will not start until the schema is correct.
        """)

        System.halt(1)

      {:error, reason} ->
        Logger.error("""
        [Subspace] STARTUP FAILED — could not query agents table: #{inspect(reason)}

        Check that:
          - The database is running and reachable
          - The DATABASE_URL / Repo config points to the correct host
          - The DB user has SELECT privileges on the agents table
          - Migrations have been run: mix ecto.migrate

        The application will not start until the schema is correct.
        """)

        System.halt(1)
    end
  end
end

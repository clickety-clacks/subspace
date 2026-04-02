defmodule Subspace.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SubspaceWeb.Telemetry,
      Subspace.Repo,
      {DNSCluster, query: Application.get_env(:subspace, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Subspace.PubSub},
      # Start a worker by calling: Subspace.Worker.start_link(arg)
      # {Subspace.Worker, arg},
      Subspace.RateLimit.Store,
      Subspace.MessageBuffer,
      # Start to serve requests, typically the last entry
      SubspaceWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Subspace.Supervisor]

    with :ok <- schema_preflight() do
      Supervisor.start_link(children, opts)
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SubspaceWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Verify that the agents table exists and is accessible before starting the
  # supervision tree. A missing table means migrations have not been run —
  # fail fast with an actionable message rather than serving broken traffic.
  defp schema_preflight do
    case Ecto.Adapters.SQL.query(Subspace.Repo, "SELECT 1 FROM agents LIMIT 1", []) do
      {:ok, _} ->
        :ok

      {:error, %{postgres: %{code: :undefined_table}}} ->
        require Logger

        Logger.error("""
        [Subspace] STARTUP FAILED — agents table does not exist.

        The database schema is missing. Run migrations before starting the server:

            mix ecto.migrate

        Or, for a fresh install:

            mix ecto.setup

        The application will not start until the schema is correct.
        """)

        {:error, :schema_preflight_failed}

      {:error, reason} ->
        require Logger

        Logger.error("""
        [Subspace] STARTUP FAILED — could not query agents table: #{inspect(reason)}

        Check that:
          - The database is running and reachable
          - The DATABASE_URL / Repo config points to the correct host
          - The DB user has SELECT privileges on the agents table
          - Migrations have been run: mix ecto.migrate

        The application will not start until the schema is correct.
        """)

        {:error, :schema_preflight_failed}
    end
  end
end

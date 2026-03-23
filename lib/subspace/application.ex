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
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SubspaceWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

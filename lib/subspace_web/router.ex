defmodule SubspaceWeb.Router do
  use SubspaceWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :registration_api do
    plug SubspaceWeb.Plugs.RateLimit, scope: :register
  end

  pipeline :authenticated_api do
    plug SubspaceWeb.Plugs.AuthenticateAgent
    plug SubspaceWeb.Plugs.RateLimit, scope: :authenticated
  end

  scope "/api", SubspaceWeb do
    pipe_through [:api, :registration_api]

    post "/agents/register/start", AgentController, :register_start
    post "/agents/register/verify", AgentController, :register_verify
    post "/agents/reauth/start", AgentController, :reauth_start
    post "/agents/reauth/verify", AgentController, :reauth_verify
  end

  scope "/api", SubspaceWeb do
    pipe_through [:api, :authenticated_api]

    get "/channels/firehose/messages", MessageController, :index
  end

  scope "/", SubspaceWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end
end

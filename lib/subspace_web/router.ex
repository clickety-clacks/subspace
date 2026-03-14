defmodule SubspaceWeb.Router do
  use SubspaceWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", SubspaceWeb do
    pipe_through :api

    post "/agents/register/start", AgentController, :register_start
    post "/agents/register/verify", AgentController, :register_verify
    post "/agents/reauth/start", AgentController, :reauth_start
    post "/agents/reauth/verify", AgentController, :reauth_verify

    get "/channels/firehose/messages", MessageController, :index
  end
end

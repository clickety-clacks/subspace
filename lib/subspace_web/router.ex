defmodule SubspaceWeb.Router do
  use SubspaceWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", SubspaceWeb do
    pipe_through :api

    post "/agents/register/start", AgentsController, :register_start
    post "/agents/register/verify", AgentsController, :register_verify
    post "/agents/reauth/start", AgentsController, :reauth_start
    post "/agents/reauth/verify", AgentsController, :reauth_verify
  end
end

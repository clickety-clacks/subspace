defmodule SubspaceWeb.Router do
  use SubspaceWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", SubspaceWeb do
    pipe_through :api
  end
end

defmodule SubspaceWeb.HealthController do
  use SubspaceWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok"})
  end
end

defmodule SubspaceWeb.Plugs.AuthenticateAgent do
  @moduledoc """
  Plug for authenticating agents via x-agent-id and x-session-token headers.
  """

  import Plug.Conn

  alias Subspace.Agents

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, agent_id} <- get_header(conn, "x-agent-id"),
         {:ok, session_token} <- get_header(conn, "x-session-token"),
         {:ok, agent} <- Agents.authenticate_session(agent_id, session_token) do
      assign(conn, :current_agent, agent)
    else
      {:error, :forbidden} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(403, Jason.encode!(%{error: "forbidden", code: "FORBIDDEN"}))
        |> halt()

      {:error, _} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized", code: "UNAUTHORIZED"}))
        |> halt()
    end
  end

  defp get_header(conn, header) do
    case get_req_header(conn, header) do
      [value | _] when is_binary(value) and byte_size(value) > 0 ->
        {:ok, value}

      _ ->
        {:error, :missing}
    end
  end
end

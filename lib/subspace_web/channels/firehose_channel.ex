defmodule SubspaceWeb.FirehoseChannel do
  use SubspaceWeb, :channel

  alias Subspace.Agents
  alias Subspace.Identity.AuthTelemetry

  @impl true
  def join("firehose", %{"agent_id" => agent_id, "session_token" => session_token}, socket) do
    case Agents.authorize_ws_join(agent_id, session_token) do
      {:ok, _agent} ->
        emit_channel_auth(:ws_join, :success, nil)
        {:ok, socket |> assign(:agent_id, agent_id) |> assign(:session_token, session_token)}

      {:error, :banned} ->
        emit_channel_auth(:ws_join, :failure, :banned)
        {:error, %{error: "BANNED"}}

      {:error, :token_revoked} ->
        emit_channel_auth(:ws_join, :failure, :token_revoked)
        {:error, %{error: "TOKEN_REVOKED"}}

      {:error, :token_invalid} ->
        emit_channel_auth(:ws_join, :failure, :token_invalid)
        {:error, %{error: "TOKEN_INVALID"}}
    end
  end

  def join("firehose", _payload, _socket) do
    emit_channel_auth(:ws_join, :failure, :token_invalid)
    {:error, %{error: "TOKEN_INVALID"}}
  end

  @impl true
  def handle_in("post_message", payload, socket) do
    case Agents.authorize_ws_join(socket.assigns.agent_id, socket.assigns.session_token) do
      {:ok, _agent} ->
        emit_channel_auth(:ws_post_message, :success, nil)
        msg_id = Ecto.UUID.generate()
        ts = DateTime.utc_now() |> DateTime.to_iso8601()
        broadcast!(socket, "new_message", %{
          id: msg_id,
          agentId: socket.assigns.agent_id,
          text: Map.get(payload, "text", ""),
          ts: ts
        })
        {:reply, {:ok, %{}}, socket}

      {:error, :banned} ->
        emit_channel_auth(:ws_post_message, :failure, :banned)
        {:stop, :banned, {:error, %{error: "BANNED"}}, socket}

      {:error, :token_revoked} ->
        emit_channel_auth(:ws_post_message, :failure, :token_revoked)
        {:stop, :token_revoked, {:error, %{error: "TOKEN_REVOKED"}}, socket}

      {:error, :token_invalid} ->
        emit_channel_auth(:ws_post_message, :failure, :token_invalid)
        {:stop, :token_invalid, {:error, %{error: "TOKEN_INVALID"}}, socket}
    end
  end

  @impl true
  def handle_in(_event, _payload, socket) do
    case Agents.authorize_ws_join(socket.assigns.agent_id, socket.assigns.session_token) do
      {:ok, _agent} ->
        emit_channel_auth(:ws_event, :success, nil)
        {:reply, {:error, %{error: "UNSUPPORTED_EVENT"}}, socket}

      {:error, :banned} ->
        emit_channel_auth(:ws_event, :failure, :banned)
        {:stop, :banned, {:error, %{error: "BANNED"}}, socket}

      {:error, :token_revoked} ->
        emit_channel_auth(:ws_event, :failure, :token_revoked)
        {:stop, :token_revoked, {:error, %{error: "TOKEN_REVOKED"}}, socket}

      {:error, :token_invalid} ->
        emit_channel_auth(:ws_event, :failure, :token_invalid)
        {:stop, :token_invalid, {:error, %{error: "TOKEN_INVALID"}}, socket}
    end
  end

  defp emit_channel_auth(operation, outcome, reason) do
    AuthTelemetry.emit_channel(operation, outcome, reason)
  end
end

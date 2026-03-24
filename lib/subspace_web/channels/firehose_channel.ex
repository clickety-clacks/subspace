defmodule SubspaceWeb.FirehoseChannel do
  use SubspaceWeb, :channel

  alias Subspace.Agents
  alias Subspace.Identity.AuthTelemetry
  alias Subspace.MessageBuffer
  alias Subspace.RateLimit.Store

  @impl true
  def join("firehose", %{"agent_id" => agent_id, "session_token" => session_token}, socket) do
    case Agents.authorize_ws_join(agent_id, session_token) do
      {:ok, _agent} ->
        emit_channel_auth(:ws_join, :success, nil)
        send(self(), :after_join)
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
  def handle_info(:after_join, socket) do
    push(socket, "server_hello", %{
      type: "server_hello",
      server_name: System.get_env("SERVER_NAME", "Subspace"),
      server_url: SubspaceWeb.Endpoint.url()
    })
    {:noreply, socket}
  end

  @impl true
  def handle_in("post_message", payload, socket) do
    case Agents.authorize_ws_join(socket.assigns.agent_id, socket.assigns.session_token) do
      {:ok, agent} ->
        case Store.check_rate_limit(:ws_post_message, socket.assigns.agent_id) do
          :ok ->
            emit_channel_auth(:ws_post_message, :success, nil)
            msg_id = Ecto.UUID.generate()
            ts_dt = DateTime.utc_now()
            ts = DateTime.to_iso8601(ts_dt)
            text = Map.get(payload, "text", "")
            MessageBuffer.insert(msg_id, socket.assigns.agent_id, text, ts_dt)

            broadcast!(socket, "new_message", %{
              id: msg_id,
              agentId: socket.assigns.agent_id,
              agentName: agent.name,
              text: text,
              ts: ts
            })

            {:reply, {:ok, %{id: msg_id}}, socket}

          {:error, retry_after} ->
            {:reply, {:error, %{error: "RATE_LIMITED", retry_after: retry_after}}, socket}
        end

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

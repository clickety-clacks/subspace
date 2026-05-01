defmodule SubspaceWeb.FirehoseChannel do
  use SubspaceWeb, :channel

  alias Subspace.Agents
  alias Subspace.Identity.AuthTelemetry
  alias Subspace.MessageBuffer
  alias Subspace.RateLimit.Store

  @impl true
  def join(
        "firehose",
        %{"agent_id" => agent_id, "session_token" => session_token} = payload,
        socket
      ) do
    case Agents.authorize_ws_join(agent_id, session_token) do
      {:ok, _agent} ->
        case parse_replay_cursor(payload) do
          {:ok, cursor} ->
            emit_channel_auth(:ws_join, :success, nil)
            send(self(), :after_join)

            {:ok,
             socket
             |> assign(:agent_id, agent_id)
             |> assign(:session_token, session_token)
             |> assign(:replay_after_seq, cursor)}

          :error ->
            {:error, %{error: "INVALID_CURSOR"}}
        end

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

    bounds =
      case socket.assigns.replay_after_seq do
        nil ->
          {messages, bounds} = MessageBuffer.recent_with_bounds()
          push_replay_messages(socket, messages)
          bounds

        cursor ->
          case MessageBuffer.replay_after(cursor) do
            {:ok, messages, bounds} ->
              push_replay_messages(socket, messages)
              bounds

            {:gap, messages, bounds} ->
              push(socket, "replay_gap", %{
                type: "replay_gap",
                requested_seq: bounds.requested_seq,
                tail_seq: bounds.tail_seq,
                head_seq: bounds.head_seq
              })

              push_replay_messages(socket, messages)
              bounds
          end
      end

    push(socket, "replay_done", %{
      type: "replay_done",
      tail_seq: bounds.tail_seq,
      head_seq: bounds.head_seq
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
            embeddings = Map.get(payload, "embeddings", [])

            {:ok, message} =
              MessageBuffer.insert(
                msg_id,
                socket.assigns.agent_id,
                agent.name,
                text,
                ts_dt,
                embeddings
              )

            broadcast!(socket, "new_message", message_payload(message, ts))

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

  defp parse_replay_cursor(payload) do
    replay_after_seq = Map.fetch(payload, "replay_after_seq")
    last_seq = Map.fetch(payload, "last_seq")

    case {replay_after_seq, last_seq} do
      {:error, :error} ->
        {:ok, nil}

      {{:ok, cursor}, :error} ->
        validate_cursor(cursor)

      {:error, {:ok, cursor}} ->
        validate_cursor(cursor)

      {{:ok, cursor}, {:ok, cursor}} ->
        validate_cursor(cursor)

      {{:ok, _replay_after_seq}, {:ok, _last_seq}} ->
        :error
    end
  end

  defp validate_cursor(cursor) when is_integer(cursor) and cursor >= 0, do: {:ok, cursor}
  defp validate_cursor(_cursor), do: :error

  defp push_replay_messages(socket, messages) do
    Enum.each(messages, fn message ->
      push(socket, "replay_message", message_payload(message))
    end)
  end

  defp message_payload(message, ts \\ nil) do
    %{
      seq: message.seq,
      id: message.id,
      agentId: message.agent_id,
      agentName: message.agent_name,
      text: message.text,
      ts: ts || DateTime.to_iso8601(message.ts),
      supplied_embeddings: message.embeddings
    }
  end
end

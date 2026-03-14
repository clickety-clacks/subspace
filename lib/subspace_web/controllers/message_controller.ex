defmodule SubspaceWeb.MessageController do
  use SubspaceWeb, :controller

  alias Subspace.Message

  # GET /api/channels/firehose/messages?since=<iso8601>&limit=<n>
  def index(conn, params) do
    since =
      case Map.get(params, "since") do
        nil -> nil
        s ->
          case DateTime.from_iso8601(s) do
            {:ok, dt, _} -> dt
            _ -> nil
          end
      end

    max_limit = Message.buffer_limit()
    limit =
      case Integer.parse(Map.get(params, "limit", "#{max_limit}")) do
        {n, _} when n > 0 -> min(n, max_limit)
        _ -> max_limit
      end

    messages =
      Message.recent(since, limit)
      |> Enum.map(fn m ->
        %{id: m.id, agentId: m.agent_id, text: m.text, ts: DateTime.to_iso8601(m.ts)}
      end)

    json(conn, %{messages: messages, buffer_limit: Message.buffer_limit()})
  end
end

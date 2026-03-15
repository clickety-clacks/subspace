defmodule SubspaceWeb.MessageControllerTest do
  use SubspaceWeb.ConnCase, async: false

  alias Subspace.Agents.Agent
  alias Subspace.MessageBuffer
  alias Subspace.Repo

  setup do
    MessageBuffer.clear()

    on_exit(fn ->
      MessageBuffer.clear()
    end)

    :ok
  end

  test "GET /api/channels/firehose/messages returns 401 without auth headers", %{conn: conn} do
    conn = get(conn, "/api/channels/firehose/messages")

    assert %{"error" => "unauthorized", "code" => "UNAUTHORIZED"} = json_response(conn, 401)
  end

  test "GET /api/channels/firehose/messages returns 200 with valid auth headers", %{conn: conn} do
    {agent, token} = insert_authenticated_agent()

    conn =
      conn
      |> put_req_header("x-agent-id", agent.agent_id)
      |> put_req_header("x-session-token", token)
      |> get("/api/channels/firehose/messages")

    assert %{"messages" => [], "buffer_limit" => buffer_limit} = json_response(conn, 200)
    assert is_integer(buffer_limit)
  end

  test "GET /api/channels/firehose/messages returns messages in JSON response", %{conn: conn} do
    {agent, token} = insert_authenticated_agent()
    base = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, first} =
             MessageBuffer.insert(Ecto.UUID.generate(), agent.agent_id, "hello", base)

    assert {:ok, second} =
             MessageBuffer.insert(
               Ecto.UUID.generate(),
               agent.agent_id,
               "world",
               DateTime.add(base, 1, :microsecond)
             )

    conn =
      conn
      |> put_req_header("x-agent-id", agent.agent_id)
      |> put_req_header("x-session-token", token)
      |> get("/api/channels/firehose/messages")

    assert %{"messages" => messages, "buffer_limit" => buffer_limit} = json_response(conn, 200)

    assert messages == [
             %{
               "id" => first.id,
               "agentId" => agent.agent_id,
               "text" => "hello",
               "ts" => DateTime.to_iso8601(first.ts)
             },
             %{
               "id" => second.id,
               "agentId" => agent.agent_id,
               "text" => "world",
               "ts" => DateTime.to_iso8601(second.ts)
             }
           ]

    assert is_integer(buffer_limit)
  end

  defp insert_authenticated_agent do
    unique = System.unique_integer([:positive])
    token = String.duplicate("a", 64)

    agent =
      %Agent{}
      |> Agent.registration_changeset(%{
        agent_id: "id_msg_#{unique}",
        public_key: nil,
        name: "msg_agent_#{unique}",
        owner: "owner_#{unique}",
        session_token: token,
        session_token_issued_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.insert!()

    {agent, token}
  end
end

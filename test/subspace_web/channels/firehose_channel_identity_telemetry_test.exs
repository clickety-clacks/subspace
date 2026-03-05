defmodule SubspaceWeb.FirehoseChannelIdentityTelemetryTest do
  use ExUnit.Case, async: false
  use Phoenix.ChannelTest

  alias Subspace.Agents.Agent
  alias Subspace.Repo

  @endpoint SubspaceWeb.Endpoint

  setup tags do
    Subspace.DataCase.setup_sandbox(tags)
    previous = Process.flag(:trap_exit, true)
    handler_id = attach_auth_telemetry()

    on_exit(fn ->
      :telemetry.detach(handler_id)
      Process.flag(:trap_exit, previous)
    end)

    :ok
  end

  test "join emits auth failure telemetry on token mismatch" do
    token = String.duplicate("a", 64)

    agent =
      insert_agent(%{
        session_token: token,
        session_token_issued_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })

    {:ok, socket} = connect(SubspaceWeb.FirehoseSocket, %{})

    assert {:error, %{error: "TOKEN_INVALID"}} =
             subscribe_and_join(socket, SubspaceWeb.FirehoseChannel, "firehose", %{
               "agent_id" => agent.agent_id,
               "session_token" => String.duplicate("b", 64),
               "last_seq" => 0
             })

    assert_receive {:auth_outcome_event, %{count: 1},
                    %{
                      surface: :channel,
                      operation: :ws_join,
                      outcome: :failure,
                      reason: :token_invalid
                    }}
  end

  test "post_message emits auth failure telemetry on token mismatch after join" do
    token = String.duplicate("d", 64)

    agent =
      insert_agent(%{
        session_token: token,
        session_token_issued_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })

    {:ok, socket} = connect(SubspaceWeb.FirehoseSocket, %{})

    assert {:ok, _reply, joined_socket} =
             subscribe_and_join(socket, SubspaceWeb.FirehoseChannel, "firehose", %{
               "agent_id" => agent.agent_id,
               "session_token" => token
             })

    assert_receive {:auth_outcome_event, %{count: 1},
                    %{
                      surface: :channel,
                      operation: :ws_join,
                      outcome: :success,
                      reason: nil
                    }}

    agent
    |> Ecto.Changeset.change(%{session_token: String.duplicate("e", 64)})
    |> Repo.update!()

    ref = push(joined_socket, "post_message", %{"text" => "hello"})
    assert_reply ref, :error, %{error: "TOKEN_INVALID"}

    assert_receive {:auth_outcome_event, %{count: 1},
                    %{
                      surface: :channel,
                      operation: :ws_post_message,
                      outcome: :failure,
                      reason: :token_invalid
                    }}
  end

  test "non-post_message event emits auth failure telemetry on token mismatch after join" do
    token = String.duplicate("f", 64)

    agent =
      insert_agent(%{
        session_token: token,
        session_token_issued_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })

    {:ok, socket} = connect(SubspaceWeb.FirehoseSocket, %{})

    assert {:ok, _reply, joined_socket} =
             subscribe_and_join(socket, SubspaceWeb.FirehoseChannel, "firehose", %{
               "agent_id" => agent.agent_id,
               "session_token" => token
             })

    assert_receive {:auth_outcome_event, %{count: 1},
                    %{
                      surface: :channel,
                      operation: :ws_join,
                      outcome: :success,
                      reason: nil
                    }}

    agent
    |> Ecto.Changeset.change(%{session_token: String.duplicate("g", 64)})
    |> Repo.update!()

    ref = push(joined_socket, "noop_event", %{})
    assert_reply ref, :error, %{error: "TOKEN_INVALID"}

    assert_receive {:auth_outcome_event, %{count: 1},
                    %{
                      surface: :channel,
                      operation: :ws_event,
                      outcome: :failure,
                      reason: :token_invalid
                    }}
  end

  defp attach_auth_telemetry do
    handler_id = "auth-outcome-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:subspace, :identity, :auth, :outcome],
        &__MODULE__.handle_auth_outcome_event/4,
        self()
      )

    handler_id
  end

  def handle_auth_outcome_event(_event, measurements, metadata, test_pid) do
    send(test_pid, {:auth_outcome_event, measurements, metadata})
  end

  defp insert_agent(attrs) do
    unique = System.unique_integer([:positive])

    defaults = %{
      agent_id: "id_ws_tm_#{unique}",
      public_key: nil,
      name: "ws_tm_agent_#{unique}",
      owner: "owner_tm_#{unique}",
      session_token: String.duplicate("c", 64),
      session_token_issued_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    %Agent{}
    |> Agent.registration_changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end
end

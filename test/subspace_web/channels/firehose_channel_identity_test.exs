defmodule SubspaceWeb.FirehoseChannelIdentityTest do
  use ExUnit.Case, async: false
  use Phoenix.ChannelTest

  alias Subspace.Agents.Agent
  alias Subspace.Identity.Config
  alias Subspace.Repo

  @endpoint SubspaceWeb.Endpoint

  setup tags do
    Subspace.DataCase.setup_sandbox(tags)
    previous = Process.flag(:trap_exit, true)

    on_exit(fn ->
      Process.flag(:trap_exit, previous)
    end)

    :ok
  end

  test "joins firehose with a non-expired session token" do
    token = String.duplicate("a", 64)

    agent =
      insert_agent(%{
        session_token: token,
        session_token_issued_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })

    {:ok, socket} = connect(SubspaceWeb.FirehoseSocket, %{})

    assert {:ok, _reply, joined_socket} =
             subscribe_and_join(socket, SubspaceWeb.FirehoseChannel, "firehose", %{
               "agent_id" => agent.agent_id,
               "session_token" => token,
               "last_seq" => 0
             })

    assert joined_socket.assigns.agent_id == agent.agent_id
  end

  test "rejects join with expired session token" do
    token = String.duplicate("b", 64)

    expired_issued_at =
      DateTime.utc_now()
      |> DateTime.add(-(Config.session_token_ttl_secs() + 1), :second)
      |> DateTime.truncate(:microsecond)

    agent =
      insert_agent(%{
        session_token: token,
        session_token_issued_at: expired_issued_at
      })

    {:ok, socket} = connect(SubspaceWeb.FirehoseSocket, %{})

    assert {:error, %{error: "TOKEN_REVOKED"}} =
             subscribe_and_join(socket, SubspaceWeb.FirehoseChannel, "firehose", %{
               "agent_id" => agent.agent_id,
               "session_token" => token,
               "last_seq" => 0
             })
  end

  test "post_message closes channel when token is revoked after join" do
    token = String.duplicate("e", 64)

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

    agent
    |> Ecto.Changeset.change(%{session_token: nil})
    |> Repo.update!()

    monitor_ref = Process.monitor(joined_socket.channel_pid)
    ref = push(joined_socket, "post_message", %{"text" => "hello"})
    assert_reply ref, :error, %{error: "TOKEN_REVOKED"}
    assert_receive {:DOWN, ^monitor_ref, :process, _pid, :token_revoked}
  end

  test "post_message closes channel when token becomes expired after join" do
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

    expired_issued_at =
      DateTime.utc_now()
      |> DateTime.add(-(Config.session_token_ttl_secs() + 1), :second)
      |> DateTime.truncate(:microsecond)

    agent
    |> Ecto.Changeset.change(%{session_token_issued_at: expired_issued_at})
    |> Repo.update!()

    monitor_ref = Process.monitor(joined_socket.channel_pid)
    ref = push(joined_socket, "post_message", %{"text" => "hello"})
    assert_reply ref, :error, %{error: "TOKEN_REVOKED"}
    assert_receive {:DOWN, ^monitor_ref, :process, _pid, :token_revoked}
  end

  test "post_message closes channel with banned reason when agent is banned after join" do
    token = String.duplicate("1", 64)

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

    agent
    |> Ecto.Changeset.change(%{banned_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)})
    |> Repo.update!()

    monitor_ref = Process.monitor(joined_socket.channel_pid)
    ref = push(joined_socket, "post_message", %{"text" => "hello"})
    assert_reply ref, :error, %{error: "BANNED"}
    assert_receive {:DOWN, ^monitor_ref, :process, _pid, :banned}
  end

  test "post_message closes channel with token_invalid reason on token mismatch after join" do
    token = String.duplicate("2", 64)

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

    agent
    |> Ecto.Changeset.change(%{session_token: String.duplicate("3", 64)})
    |> Repo.update!()

    monitor_ref = Process.monitor(joined_socket.channel_pid)
    ref = push(joined_socket, "post_message", %{"text" => "hello"})
    assert_reply ref, :error, %{error: "TOKEN_INVALID"}
    assert_receive {:DOWN, ^monitor_ref, :process, _pid, :token_invalid}
  end

  test "non-post_message event returns unsupported event when token is still valid" do
    token = String.duplicate("4", 64)

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

    ref = push(joined_socket, "noop_event", %{})
    assert_reply ref, :error, %{error: "UNSUPPORTED_EVENT"}

    post_ref = push(joined_socket, "post_message", %{"text" => "still connected"})
    assert_reply post_ref, :ok, %{}
  end

  test "non-post_message event closes channel when token is revoked after join" do
    token = String.duplicate("5", 64)

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

    agent
    |> Ecto.Changeset.change(%{session_token: nil})
    |> Repo.update!()

    monitor_ref = Process.monitor(joined_socket.channel_pid)
    ref = push(joined_socket, "noop_event", %{})
    assert_reply ref, :error, %{error: "TOKEN_REVOKED"}
    assert_receive {:DOWN, ^monitor_ref, :process, _pid, :token_revoked}
  end

  test "non-post_message event closes channel with token_invalid on token mismatch" do
    token = String.duplicate("6", 64)

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

    agent
    |> Ecto.Changeset.change(%{session_token: String.duplicate("7", 64)})
    |> Repo.update!()

    monitor_ref = Process.monitor(joined_socket.channel_pid)
    ref = push(joined_socket, "noop_event", %{})
    assert_reply ref, :error, %{error: "TOKEN_INVALID"}
    assert_receive {:DOWN, ^monitor_ref, :process, _pid, :token_invalid}
  end

  defp insert_agent(attrs) do
    unique = System.unique_integer([:positive])

    defaults = %{
      agent_id: "id_ws_#{unique}",
      public_key: nil,
      name: "ws_agent_#{unique}",
      owner: "owner_#{unique}",
      session_token: String.duplicate("c", 64),
      session_token_issued_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    %Agent{}
    |> Agent.registration_changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end
end

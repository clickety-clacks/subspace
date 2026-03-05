defmodule SubspaceWeb.AgentControllerIdentityTelemetryTest do
  use SubspaceWeb.ConnCase, async: false

  test "register_start emits auth success telemetry in phase-1 local_keypair mode", %{conn: conn} do
    with_identity_config(mode: "local_keypair")
    attach_auth_telemetry()

    conn =
      post(conn, "/api/agents/register/start", %{
        "name" => "clu",
        "owner" => "flynn",
        "publicKey" => "pk_test"
      })

    assert %{"challengeId" => _challenge_id, "challenge" => _challenge} = json_response(conn, 200)

    assert_receive {:auth_outcome_event, %{count: 1},
                    %{
                      surface: :http,
                      operation: :register_start,
                      outcome: :success,
                      reason: nil,
                      mode: :local_keypair
                    }}
  end

  test "register_start emits auth failure telemetry for invalid input in phase-1 local_keypair mode",
       %{
         conn: conn
       } do
    with_identity_config(mode: "local_keypair")
    attach_auth_telemetry()

    conn = post(conn, "/api/agents/register/start", %{"name" => "clu", "publicKey" => "pk_test"})
    assert %{"error" => "invalid input", "code" => "INVALID_INPUT"} = json_response(conn, 400)

    assert_receive {:auth_outcome_event, %{count: 1},
                    %{
                      surface: :http,
                      operation: :register_start,
                      outcome: :failure,
                      reason: :invalid_input,
                      mode: :local_keypair
                    }}
  end

  defp with_identity_config(overrides) do
    previous_identity = Application.get_env(:subspace, :identity, [])
    updated = Keyword.merge(previous_identity, overrides)
    Application.put_env(:subspace, :identity, updated)

    on_exit(fn ->
      Application.put_env(:subspace, :identity, previous_identity)
    end)
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

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)
  end

  def handle_auth_outcome_event(_event, measurements, metadata, test_pid) do
    send(test_pid, {:auth_outcome_event, measurements, metadata})
  end
end

defmodule Subspace.Identity.AuthTelemetry do
  @moduledoc false

  @event [:subspace, :identity, :auth, :outcome]
  @jwks_refresh_event [:subspace, :identity, :jwks, :refresh]

  def emit_http(operation, outcome, reason, mode) do
    emit(%{
      surface: :http,
      operation: operation,
      outcome: outcome,
      reason: reason,
      mode: mode
    })
  end

  def emit_channel(operation, outcome, reason) do
    emit(%{
      surface: :channel,
      operation: operation,
      outcome: outcome,
      reason: reason
    })
  end

  def emit_jwks_refresh(decision, outcome, reason) do
    :telemetry.execute(
      @jwks_refresh_event,
      %{count: 1},
      %{decision: decision, outcome: outcome, reason: reason}
    )
  end

  defp emit(metadata) do
    :telemetry.execute(@event, %{count: 1}, metadata)
  end
end

defmodule Subspace.IdentityAssertionVerifierJwksRateLimitTest do
  use ExUnit.Case, async: false

  alias Subspace.IdentityAssertionVerifier

  defmodule CountingJwksFetcher do
    @behaviour Subspace.Identity.JwksFetcher

    @impl true
    def fetch(_url) do
      counter_pid = Application.fetch_env!(:subspace, :identity_test_jwks_fetch_counter)
      Agent.update(counter_pid, &(&1 + 1))
      {:ok, %{"keys" => []}}
    end
  end

  setup do
    previous_identity = Application.get_env(:subspace, :identity, [])
    previous_fetcher = Application.get_env(:subspace, :identity_jwks_fetcher)
    previous_counter = Application.get_env(:subspace, :identity_test_jwks_fetch_counter)
    previous_now_unix_fn = Application.get_env(:subspace, :identity_now_unix_fn)
    previous_runtime_env_override = Application.get_env(:subspace, :identity_runtime_env_override)

    {:ok, time_pid} = Agent.start_link(fn -> 1_700_000_000 end)
    {:ok, counter_pid} = Agent.start_link(fn -> 0 end)

    Application.put_env(
      :subspace,
      :identity,
      Keyword.merge(previous_identity,
        mode: "external_service",
        issuer_url: "https://identity.example",
        issuer_jwks_url: "https://identity.example/.well-known/jwks.json",
        assertion_audience: "subspace",
        service_id: "subspace-main",
        assertion_max_age_secs: 120,
        jwks_cache_ttl_secs: 300
      )
    )

    Application.put_env(:subspace, :identity_jwks_fetcher, CountingJwksFetcher)
    Application.put_env(:subspace, :identity_test_jwks_fetch_counter, counter_pid)
    Application.put_env(:subspace, :identity_now_unix_fn, fn -> Agent.get(time_pid, & &1) end)
    telemetry_handler_id = attach_jwks_refresh_telemetry()

    clear_jwks_cache()

    on_exit(fn ->
      clear_jwks_cache()
      :telemetry.detach(telemetry_handler_id)
      Application.put_env(:subspace, :identity, previous_identity)
      restore_optional_env(:identity_jwks_fetcher, previous_fetcher)
      restore_optional_env(:identity_test_jwks_fetch_counter, previous_counter)
      restore_optional_env(:identity_now_unix_fn, previous_now_unix_fn)
      restore_optional_env(:identity_runtime_env_override, previous_runtime_env_override)
    end)

    {:ok, time_pid: time_pid, counter_pid: counter_pid}
  end

  test "repeated kid miss within forced refresh window does not re-fetch JWKS", %{
    counter_pid: counter_pid
  } do
    assertion = kid_miss_assertion("missing-kid-within")

    assert {:error, :assertion_invalid} = IdentityAssertionVerifier.verify(assertion)
    assert fetch_count(counter_pid) == 2

    assert_receive {:jwks_refresh_event, %{count: 1},
                    %{decision: :attempted, outcome: :success, reason: nil}}

    assert {:error, :assertion_invalid} = IdentityAssertionVerifier.verify(assertion)
    assert fetch_count(counter_pid) == 2

    assert_receive {:jwks_refresh_event, %{count: 1},
                    %{
                      decision: :rate_limited,
                      outcome: :skipped,
                      reason: :forced_refresh_interval
                    }}
  end

  test "repeated kid miss after forced refresh window re-fetches JWKS", %{
    counter_pid: counter_pid,
    time_pid: time_pid
  } do
    assertion = kid_miss_assertion("missing-kid-after")

    assert {:error, :assertion_invalid} = IdentityAssertionVerifier.verify(assertion)
    assert fetch_count(counter_pid) == 2

    Agent.update(time_pid, &(&1 + 61))

    assert {:error, :assertion_invalid} = IdentityAssertionVerifier.verify(assertion)
    assert fetch_count(counter_pid) == 3
  end

  test "non-test runtime path ignores deterministic clock override config", %{
    counter_pid: counter_pid,
    time_pid: time_pid
  } do
    Application.put_env(:subspace, :identity_runtime_env_override, :prod)

    Application.put_env(:subspace, :identity_now_unix_fn, fn ->
      Agent.get_and_update(time_pid, fn now -> {now, now + 61} end)
    end)

    assertion = kid_miss_assertion("missing-kid-prod-path")

    assert {:error, :assertion_invalid} = IdentityAssertionVerifier.verify(assertion)
    assert fetch_count(counter_pid) == 2

    assert {:error, :assertion_invalid} = IdentityAssertionVerifier.verify(assertion)
    assert fetch_count(counter_pid) == 2
  end

  defp kid_miss_assertion(kid) do
    header = %{"alg" => "EdDSA", "kid" => kid} |> Jason.encode!() |> b64url()
    claims = %{"kind" => "kid_miss"} |> Jason.encode!() |> b64url()
    signature = "sig" |> b64url()
    header <> "." <> claims <> "." <> signature
  end

  defp fetch_count(counter_pid), do: Agent.get(counter_pid, & &1)

  defp b64url(value), do: Base.url_encode64(value, padding: false)

  defp clear_jwks_cache do
    case :ets.whereis(:subspace_identity_jwks_cache) do
      :undefined -> :ok
      _tid -> :ets.delete_all_objects(:subspace_identity_jwks_cache)
    end
  end

  defp attach_jwks_refresh_telemetry do
    handler_id = "jwks-refresh-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:subspace, :identity, :jwks, :refresh],
        &__MODULE__.handle_jwks_refresh_event/4,
        self()
      )

    handler_id
  end

  def handle_jwks_refresh_event(_event, measurements, metadata, test_pid) do
    send(test_pid, {:jwks_refresh_event, measurements, metadata})
  end

  defp restore_optional_env(key, nil), do: Application.delete_env(:subspace, key)
  defp restore_optional_env(key, value), do: Application.put_env(:subspace, key, value)
end

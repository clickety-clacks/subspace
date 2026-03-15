defmodule Subspace.Identity.StatusRateLimiterTest do
  use ExUnit.Case, async: false

  alias Subspace.Identity.StatusRateLimiter

  setup do
    previous_identity = Application.get_env(:subspace, :identity, [])

    StatusRateLimiter.clear()

    on_exit(fn ->
      Application.put_env(:subspace, :identity, previous_identity)
      StatusRateLimiter.clear()
    end)

    :ok
  end

  test "cleanup_expired/0 prunes stale entries while active limits remain enforced" do
    with_identity_config(
      identity_status_rate_limit_max_requests: 2,
      identity_status_rate_limit_window_secs: 60
    )

    assert StatusRateLimiter.allow?("active-client")

    now_unix = DateTime.utc_now() |> DateTime.to_unix()
    :ets.insert(:subspace_identity_status_rate_limit, {"stale-client", now_unix - 120, 1})

    assert [{"stale-client", _, _}] =
             :ets.lookup(:subspace_identity_status_rate_limit, "stale-client")

    assert StatusRateLimiter.cleanup_expired() == 1
    assert [] == :ets.lookup(:subspace_identity_status_rate_limit, "stale-client")

    assert [{"active-client", _, _}] =
             :ets.lookup(:subspace_identity_status_rate_limit, "active-client")

    assert StatusRateLimiter.allow?("active-client")
    refute StatusRateLimiter.allow?("active-client")
  end

  test "allow?/1 cleanup hook is throttled while active limit checks continue to work" do
    with_identity_config(
      identity_status_rate_limit_max_requests: 2,
      identity_status_rate_limit_window_secs: 60
    )

    _ = StatusRateLimiter.cleanup_expired()

    now_unix = DateTime.utc_now() |> DateTime.to_unix()
    :ets.insert(:subspace_identity_status_rate_limit, {"stale-first", now_unix - 120, 1})

    assert StatusRateLimiter.allow?("hook-client")
    assert [] == :ets.lookup(:subspace_identity_status_rate_limit, "stale-first")

    :ets.insert(:subspace_identity_status_rate_limit, {"stale-second", now_unix - 120, 1})

    assert StatusRateLimiter.allow?("hook-client")

    assert [{"stale-second", _, _}] =
             :ets.lookup(:subspace_identity_status_rate_limit, "stale-second")

    refute StatusRateLimiter.allow?("hook-client")
  end

  defp with_identity_config(overrides) do
    previous_identity = Application.get_env(:subspace, :identity, [])
    Application.put_env(:subspace, :identity, Keyword.merge(previous_identity, overrides))

    on_exit(fn ->
      Application.put_env(:subspace, :identity, previous_identity)
    end)
  end
end

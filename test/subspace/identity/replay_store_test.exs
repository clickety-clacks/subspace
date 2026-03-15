defmodule Subspace.Identity.ReplayStoreTest do
  use Subspace.DataCase, async: false

  alias Subspace.Identity.AssertionReplay
  alias Subspace.Identity.ReplayStore
  alias Subspace.Repo

  setup do
    case :ets.whereis(:subspace_identity_replay_cleanup_meta) do
      :undefined -> :ok
      _tid -> :ets.delete_all_objects(:subspace_identity_replay_cleanup_meta)
    end

    :ok
  end

  test "cleanup_expired/0 removes expired rows and keeps active rows" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all(AssertionReplay, [
      %{
        jti: "expired_jti",
        expires_at: DateTime.add(now, -1, :second),
        inserted_at: now,
        updated_at: now
      },
      %{
        jti: "active_jti",
        expires_at: DateTime.add(now, 60, :second),
        inserted_at: now,
        updated_at: now
      }
    ])

    assert ReplayStore.cleanup_expired() == 1
    assert Repo.get(AssertionReplay, "expired_jti") == nil
    assert Repo.get(AssertionReplay, "active_jti")
  end

  test "claim/1 triggers cleanup hook for expired rows" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all(AssertionReplay, [
      %{
        jti: "expired_before_claim",
        expires_at: DateTime.add(now, -10, :second),
        inserted_at: now,
        updated_at: now
      }
    ])

    assert :ok = ReplayStore.claim("fresh_claim_jti")
    assert Repo.get(AssertionReplay, "expired_before_claim") == nil
    assert Repo.get(AssertionReplay, "fresh_claim_jti")
  end

  test "claim/1 preserves replay guarantee for active jti" do
    assert :ok = ReplayStore.claim("duplicate_jti")
    assert {:error, :assertion_replayed} = ReplayStore.claim("duplicate_jti")
  end
end

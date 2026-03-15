defmodule Subspace.Identity.ReplayStore do
  @moduledoc false

  import Ecto.Query

  alias Subspace.Identity.AssertionReplay
  alias Subspace.Identity.Config
  alias Subspace.Repo

  @cleanup_meta_table :subspace_identity_replay_cleanup_meta
  @cleanup_interval_secs 60

  def claim(jti) when is_binary(jti) do
    now = now_utc()

    maybe_cleanup_expired(now)

    Repo.delete_all(
      from replay in AssertionReplay,
        where: replay.jti == ^jti and replay.expires_at <= ^now
    )

    expires_at = DateTime.add(now, Config.assertion_replay_ttl_secs(), :second)

    {inserted, _rows} =
      Repo.insert_all(
        AssertionReplay,
        [
          %{
            jti: jti,
            expires_at: expires_at,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:jti]
      )

    if inserted == 1 do
      :ok
    else
      {:error, :assertion_replayed}
    end
  end

  def cleanup_expired do
    cleanup_expired_at(now_utc())
  end

  defp cleanup_expired_at(now) do
    {count, _rows} =
      Repo.delete_all(
        from replay in AssertionReplay,
          where: replay.expires_at <= ^now
      )

    count
  end

  defp maybe_cleanup_expired(now) do
    ensure_cleanup_meta_table!()
    now_unix = DateTime.to_unix(now)

    case :ets.lookup(@cleanup_meta_table, :last_cleanup_unix) do
      [{:last_cleanup_unix, last}]
      when is_integer(last) and now_unix - last < @cleanup_interval_secs ->
        :ok

      _ ->
        _deleted = cleanup_expired_at(now)
        :ets.insert(@cleanup_meta_table, {:last_cleanup_unix, now_unix})
        :ok
    end
  end

  defp ensure_cleanup_meta_table! do
    case :ets.whereis(@cleanup_meta_table) do
      :undefined ->
        :ets.new(@cleanup_meta_table, [:named_table, :set, :public, read_concurrency: true])
        :ok

      _tid ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp now_utc do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end
end

defmodule Subspace.Identity.Status do
  @moduledoc false

  import Ecto.Query

  @schema_version "1"

  alias Subspace.Identity.AssertionReplay
  alias Subspace.Identity.Config
  alias Subspace.Identity.JwksCache
  alias Subspace.Identity.StatusRateLimiter
  alias Subspace.Repo

  def summary do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    now_unix = DateTime.to_unix(now)
    jwks_url = Config.issuer_jwks_url()

    %{
      version: @schema_version,
      mode: Config.mode() |> Atom.to_string(),
      issuer_configured: configured?(Config.issuer_url()),
      issuer_jwks_configured: configured?(jwks_url),
      service_id_configured: configured?(Config.service_id()),
      jwks_cache: jwks_cache_summary(jwks_url, now_unix),
      replay_store: replay_store_summary(now),
      status_rate_limiter: StatusRateLimiter.diagnostics()
    }
  end

  def schema_version, do: @schema_version

  defp jwks_cache_summary(jwks_url, now_unix) do
    if configured?(jwks_url) do
      case JwksCache.get(jwks_url) do
        {:ok, entry} ->
          fetched_at_unix = Map.get(entry, :fetched_at_unix)

          %{
            configured: true,
            entry_present: true,
            key_count: entry |> Map.get(:keys, []) |> length(),
            fetched_at_unix: fetched_at_unix,
            cache_age_secs: cache_age(now_unix, fetched_at_unix),
            cache_ttl_secs: Config.jwks_cache_ttl_secs(),
            forced_refresh_at_unix: Map.get(entry, :forced_refresh_at_unix)
          }

        :error ->
          %{
            configured: true,
            entry_present: false,
            key_count: 0,
            fetched_at_unix: nil,
            cache_age_secs: nil,
            cache_ttl_secs: Config.jwks_cache_ttl_secs(),
            forced_refresh_at_unix: nil
          }
      end
    else
      %{
        configured: false,
        entry_present: false,
        key_count: 0,
        fetched_at_unix: nil,
        cache_age_secs: nil,
        cache_ttl_secs: Config.jwks_cache_ttl_secs(),
        forced_refresh_at_unix: nil
      }
    end
  end

  defp replay_store_summary(now) do
    total_entries = Repo.aggregate(AssertionReplay, :count, :jti)

    active_entries =
      Repo.one(
        from replay in AssertionReplay,
          where: replay.expires_at > ^now,
          select: count(replay.jti)
      )

    expired_entries = max(total_entries - active_entries, 0)

    %{
      status: "ok",
      total_entries: total_entries,
      active_entries: active_entries,
      expired_entries: expired_entries
    }
  rescue
    _ ->
      %{
        status: "unavailable",
        total_entries: nil,
        active_entries: nil,
        expired_entries: nil
      }
  catch
    :exit, _ ->
      %{
        status: "unavailable",
        total_entries: nil,
        active_entries: nil,
        expired_entries: nil
      }
  end

  defp configured?(value), do: is_binary(value) and String.trim(value) != ""

  defp cache_age(now_unix, fetched_at_unix) when is_integer(fetched_at_unix),
    do: max(now_unix - fetched_at_unix, 0)

  defp cache_age(_now_unix, _fetched_at_unix), do: nil
end

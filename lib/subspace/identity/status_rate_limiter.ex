defmodule Subspace.Identity.StatusRateLimiter do
  @moduledoc false

  alias Subspace.Identity.Config

  @table :subspace_identity_status_rate_limit
  @cleanup_meta_table :subspace_identity_status_rate_limit_cleanup_meta
  @cleanup_interval_secs 60
  @default_window_secs 60
  @default_max_requests 30

  def allow?(client_id) when is_binary(client_id) do
    case allow_with_retry(client_id) do
      :ok -> true
      {:error, _retry_after_secs} -> false
    end
  end

  def allow_with_retry(client_id) when is_binary(client_id) do
    ensure_table!()

    now_unix = now_unix()
    {window_secs, max_requests} = effective_limits()

    maybe_cleanup_expired(now_unix, window_secs)

    case :ets.lookup(@table, client_id) do
      [] ->
        :ets.insert(@table, {client_id, now_unix, 1})
        :ok

      [{^client_id, window_start_unix, count}]
      when is_integer(window_start_unix) and is_integer(count) ->
        if now_unix - window_start_unix >= window_secs do
          :ets.insert(@table, {client_id, now_unix, 1})
          :ok
        else
          if count < max_requests do
            :ets.insert(@table, {client_id, window_start_unix, count + 1})
            :ok
          else
            elapsed = now_unix - window_start_unix
            retry_after_secs = max(window_secs - elapsed, 1)
            {:error, retry_after_secs}
          end
        end
    end
  end

  def cleanup_expired do
    ensure_table!()
    {window_secs, _max_requests} = effective_limits()
    now_unix = now_unix()
    cleanup_expired_at(now_unix, window_secs)
  end

  def diagnostics do
    ensure_table!()
    ensure_cleanup_meta_table!()

    now_unix = now_unix()
    raw_window_secs = Config.identity_status_rate_limit_window_secs()
    raw_max_requests = Config.identity_status_rate_limit_max_requests()
    {effective_window_secs, effective_max_requests} = effective_limits()
    configured = positive_int?(raw_window_secs) and positive_int?(raw_max_requests)

    %{
      enabled: effective_window_secs > 0 and effective_max_requests > 0,
      configured: configured,
      tracked_clients: table_size(),
      cleanup_age_secs: cleanup_age_secs(now_unix)
    }
  end

  def clear do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _tid -> :ets.delete_all_objects(@table)
    end

    case :ets.whereis(@cleanup_meta_table) do
      :undefined -> :ok
      _tid -> :ets.delete_all_objects(@cleanup_meta_table)
    end
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
        :ok

      _tid ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp maybe_cleanup_expired(now_unix, window_secs) do
    ensure_cleanup_meta_table!()

    case :ets.lookup(@cleanup_meta_table, :last_cleanup_unix) do
      [{:last_cleanup_unix, last}]
      when is_integer(last) and now_unix - last < @cleanup_interval_secs ->
        :ok

      _ ->
        _deleted = cleanup_expired_at(now_unix, window_secs)
        :ets.insert(@cleanup_meta_table, {:last_cleanup_unix, now_unix})
        :ok
    end
  end

  defp cleanup_expired_at(now_unix, window_secs) do
    cutoff = now_unix - window_secs

    :ets.select_delete(@table, [
      {{:"$1", :"$2", :"$3"}, [{:"=<", :"$2", cutoff}], [true]}
    ])
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

  defp table_size do
    case :ets.info(@table, :size) do
      :undefined -> 0
      size when is_integer(size) -> size
      _ -> 0
    end
  end

  defp cleanup_age_secs(now_unix) do
    case :ets.lookup(@cleanup_meta_table, :last_cleanup_unix) do
      [{:last_cleanup_unix, last_cleanup_unix}] when is_integer(last_cleanup_unix) ->
        max(now_unix - last_cleanup_unix, 0)

      _ ->
        nil
    end
  end

  defp effective_limits do
    {
      positive_int(Config.identity_status_rate_limit_window_secs(), @default_window_secs),
      positive_int(Config.identity_status_rate_limit_max_requests(), @default_max_requests)
    }
  end

  defp now_unix do
    if Mix.env() == :test do
      case Application.get_env(:subspace, :identity_status_now_unix_fn) do
        fun when is_function(fun, 0) -> fun.()
        _ -> DateTime.utc_now() |> DateTime.to_unix()
      end
    else
      DateTime.utc_now() |> DateTime.to_unix()
    end
  end

  defp positive_int(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, fallback), do: fallback
  defp positive_int?(value), do: is_integer(value) and value > 0
end

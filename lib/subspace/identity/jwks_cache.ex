defmodule Subspace.Identity.JwksCache do
  @moduledoc false

  @table :subspace_identity_jwks_cache

  def get(url) when is_binary(url) do
    ensure_table!()

    case :ets.lookup(@table, url) do
      [{^url, entry}] -> {:ok, entry}
      [] -> :error
    end
  end

  def put(url, keys, fetched_at_unix)
      when is_binary(url) and is_list(keys) and is_integer(fetched_at_unix) do
    ensure_table!()

    entry =
      case get(url) do
        {:ok, existing} -> Map.merge(existing, %{keys: keys, fetched_at_unix: fetched_at_unix})
        :error -> %{keys: keys, fetched_at_unix: fetched_at_unix, forced_refresh_at_unix: nil}
      end

    :ets.insert(@table, {url, entry})
    :ok
  end

  def mark_forced_refresh(url, at_unix) when is_binary(url) and is_integer(at_unix) do
    ensure_table!()

    entry =
      case get(url) do
        {:ok, existing} -> Map.put(existing, :forced_refresh_at_unix, at_unix)
        :error -> %{keys: [], fetched_at_unix: 0, forced_refresh_at_unix: at_unix}
      end

    :ets.insert(@table, {url, entry})
    :ok
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
end

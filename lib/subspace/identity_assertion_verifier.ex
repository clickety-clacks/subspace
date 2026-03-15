defmodule Subspace.IdentityAssertionVerifier do
  @moduledoc false

  alias Subspace.Crypto.Base64Url
  alias Subspace.Identity.AuthTelemetry
  alias Subspace.Identity.Config
  alias Subspace.Identity.JwksCache
  alias Subspace.Identity.JwksHttpFetcher
  alias Subspace.Identity.ReplayStore

  @forced_refresh_interval_secs 60

  def verify(assertion) when is_binary(assertion) do
    with :ok <- validate_runtime_config(),
         {:ok, protected_b64, claims_b64, signature_b64} <- split_jws(assertion),
         {:ok, %{"alg" => "EdDSA", "kid" => kid}} <- decode_json_segment(protected_b64),
         {:ok, public_key} <- fetch_public_key(kid),
         {:ok, signature} <- Base64Url.decode(signature_b64),
         true <- valid_signature?(protected_b64, claims_b64, signature, public_key),
         {:ok, claims} <- decode_json_segment(claims_b64),
         :ok <- validate_claims(claims),
         :ok <- ReplayStore.claim(claims["jti"]) do
      {:ok,
       %{
         agent_id: claims["sub"],
         display_name: claims["display_name"]
       }}
    else
      {:error, :assertion_replayed} -> {:error, :assertion_replayed}
      {:error, :identity_unavailable} -> {:error, :identity_unavailable}
      _ -> {:error, :assertion_invalid}
    end
  end

  defp validate_runtime_config do
    with true <- is_binary(Config.issuer_url()) and Config.issuer_url() != "",
         true <- is_binary(Config.issuer_jwks_url()) and Config.issuer_jwks_url() != "",
         true <- is_binary(Config.service_id()) and Config.service_id() != "" do
      :ok
    else
      _ -> {:error, :identity_unavailable}
    end
  end

  defp split_jws(assertion) do
    case String.split(assertion, ".", parts: 3) do
      [protected_b64, claims_b64, signature_b64] ->
        {:ok, protected_b64, claims_b64, signature_b64}

      _ ->
        {:error, :assertion_invalid}
    end
  end

  defp valid_signature?(protected_b64, claims_b64, signature, public_key) do
    signing_input = protected_b64 <> "." <> claims_b64

    :crypto.verify(:eddsa, :none, signing_input, signature, [public_key, :ed25519])
  end

  defp decode_json_segment(segment) do
    with {:ok, decoded} <- Base64Url.decode(segment),
         {:ok, map} <- Jason.decode(decoded) do
      {:ok, map}
    else
      _ -> {:error, :assertion_invalid}
    end
  end

  defp fetch_public_key(kid) when is_binary(kid) do
    with {:ok, keys} <- get_keys(),
         {:ok, key} <- find_key_after_forced_refresh(keys, kid),
         {:ok, public_key} <- parse_key(key) do
      {:ok, public_key}
    else
      {:error, :identity_unavailable} -> {:error, :identity_unavailable}
      _ -> {:error, :assertion_invalid}
    end
  end

  defp get_keys do
    now_unix = now_unix()
    ttl_secs = Config.jwks_cache_ttl_secs()
    jwks_url = Config.issuer_jwks_url()
    cache_entry = get_cache_entry(jwks_url)

    cond do
      cache_valid?(cache_entry, now_unix, ttl_secs) ->
        {:ok, cache_entry.keys}

      true ->
        case fetch_and_store_keys(jwks_url, now_unix) do
          {:ok, keys} -> {:ok, keys}
          {:error, :identity_unavailable} -> {:error, :identity_unavailable}
        end
    end
  end

  defp find_key_after_forced_refresh(keys, kid) do
    case find_key(keys, kid) do
      {:ok, key} ->
        {:ok, key}

      {:error, :assertion_invalid} ->
        maybe_force_refresh_on_kid_miss(keys, kid)
    end
  end

  defp maybe_force_refresh_on_kid_miss(current_keys, kid) do
    now_unix = now_unix()
    jwks_url = Config.issuer_jwks_url()
    entry = get_cache_entry(jwks_url)

    if forced_refresh_allowed?(entry, now_unix) do
      :ok = JwksCache.mark_forced_refresh(jwks_url, now_unix)

      case fetch_and_store_keys(jwks_url, now_unix) do
        {:ok, refreshed_keys} ->
          AuthTelemetry.emit_jwks_refresh(:attempted, :success, nil)
          find_key(refreshed_keys, kid)

        {:error, :identity_unavailable} ->
          AuthTelemetry.emit_jwks_refresh(:attempted, :failure, :identity_unavailable)
          find_key(current_keys, kid)
      end
    else
      AuthTelemetry.emit_jwks_refresh(:rate_limited, :skipped, :forced_refresh_interval)
      find_key(current_keys, kid)
    end
  end

  defp forced_refresh_allowed?(nil, _now_unix), do: true

  defp forced_refresh_allowed?(entry, now_unix) do
    case Map.get(entry, :forced_refresh_at_unix) do
      nil ->
        true

      last_forced when is_integer(last_forced) ->
        now_unix - last_forced >= @forced_refresh_interval_secs

      _ ->
        true
    end
  end

  defp fetch_and_store_keys(jwks_url, now_unix) do
    fetcher = jwks_fetcher()

    with {:ok, body} <- fetcher.fetch(jwks_url),
         {:ok, keys} <- normalize_jwks(body) do
      :ok = JwksCache.put(jwks_url, keys, now_unix)
      {:ok, keys}
    else
      _ -> {:error, :identity_unavailable}
    end
  end

  defp get_cache_entry(jwks_url) do
    case JwksCache.get(jwks_url) do
      {:ok, entry} -> entry
      :error -> nil
    end
  end

  defp cache_valid?(nil, _now_unix, _ttl_secs), do: false

  defp cache_valid?(entry, now_unix, ttl_secs) do
    fetched_at_unix = Map.get(entry, :fetched_at_unix)
    is_integer(fetched_at_unix) and now_unix - fetched_at_unix <= ttl_secs
  end

  defp jwks_fetcher do
    if Mix.env() == :test do
      Application.get_env(:subspace, :identity_jwks_fetcher, JwksHttpFetcher)
    else
      JwksHttpFetcher
    end
  end

  defp normalize_jwks(%{"keys" => keys}) when is_list(keys), do: {:ok, keys}
  defp normalize_jwks(%{keys: keys}) when is_list(keys), do: {:ok, keys}

  defp normalize_jwks(body) when is_binary(body) do
    with {:ok, decoded} <- Jason.decode(body) do
      normalize_jwks(decoded)
    else
      _ -> {:error, :identity_unavailable}
    end
  end

  defp normalize_jwks(_), do: {:error, :identity_unavailable}

  defp find_key(keys, kid) do
    case Enum.find(keys, &(Map.get(&1, "kid") == kid or Map.get(&1, :kid) == kid)) do
      nil -> {:error, :assertion_invalid}
      key -> {:ok, key}
    end
  end

  defp parse_key(key) do
    with "OKP" <- Map.get(key, "kty") || Map.get(key, :kty),
         "Ed25519" <- Map.get(key, "crv") || Map.get(key, :crv),
         x when is_binary(x) <- Map.get(key, "x") || Map.get(key, :x),
         {:ok, raw_key} <- Base64Url.decode(x) do
      {:ok, raw_key}
    else
      _ -> {:error, :assertion_invalid}
    end
  end

  defp validate_claims(claims) do
    expected_issuer = Config.issuer_url()
    expected_audience = Config.assertion_audience()
    expected_service = Config.service_id()
    max_age_secs = Config.assertion_max_age_secs()
    now = now_unix()

    with true <- claims["iss"] == expected_issuer,
         true <- aud_matches?(claims["aud"], expected_audience),
         true <- claims["service_id"] == expected_service,
         true <- is_integer(claims["iat"]),
         true <- is_integer(claims["exp"]),
         true <- claims["iat"] <= now,
         true <- now <= claims["exp"],
         true <- now - claims["iat"] <= max_age_secs,
         true <- is_binary(claims["jti"]),
         true <- is_binary(claims["sub"]),
         true <- is_binary(claims["display_name"]) do
      :ok
    else
      _ -> {:error, :assertion_invalid}
    end
  end

  defp aud_matches?(aud, expected) when is_binary(aud), do: aud == expected
  defp aud_matches?(aud, expected) when is_list(aud), do: expected in aud
  defp aud_matches?(_, _), do: false

  defp now_unix do
    if runtime_env() == :test do
      case Application.get_env(:subspace, :identity_now_unix_fn) do
        fun when is_function(fun, 0) -> fun.()
        _ -> DateTime.utc_now() |> DateTime.to_unix()
      end
    else
      DateTime.utc_now() |> DateTime.to_unix()
    end
  end

  defp runtime_env do
    if Mix.env() == :test do
      Application.get_env(:subspace, :identity_runtime_env_override, :test)
    else
      Mix.env()
    end
  end
end

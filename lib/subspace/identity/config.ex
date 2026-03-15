defmodule Subspace.Identity.Config do
  @moduledoc false

  @type mode :: :local_keypair

  def mode, do: :local_keypair

  def issuer_url, do: identity_env(:issuer_url)
  def issuer_jwks_url, do: identity_env(:issuer_jwks_url)
  def jwks_cache_ttl_secs, do: identity_env(:jwks_cache_ttl_secs, 300)
  def assertion_audience, do: identity_env(:assertion_audience, "subspace")
  def assertion_max_age_secs, do: identity_env(:assertion_max_age_secs, 120)
  def assertion_replay_ttl_secs, do: identity_env(:assertion_replay_ttl_secs, 300)
  def service_id, do: identity_env(:service_id)
  def identity_status_token, do: identity_env(:identity_status_token)

  def identity_status_rate_limit_max_requests,
    do: identity_env(:identity_status_rate_limit_max_requests, 30)

  def identity_status_rate_limit_window_secs,
    do: identity_env(:identity_status_rate_limit_window_secs, 60)

  def session_token_ttl_secs, do: identity_env(:session_token_ttl_secs, 2_592_000)
  def local_challenge_ttl_secs, do: identity_env(:local_challenge_ttl_secs, 120)

  defp identity_env(key, default \\ nil) do
    :subspace
    |> Application.get_env(:identity, [])
    |> Keyword.get(key, default)
  end
end

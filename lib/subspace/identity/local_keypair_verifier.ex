defmodule Subspace.Identity.LocalKeypairVerifier do
  @moduledoc false

  alias Subspace.Crypto.Base64Url

  def verify_register_signature(challenge, name, owner, public_key, signature) do
    payload =
      Jason.encode!(%{
        "challenge" => challenge,
        "name" => name,
        "owner" => owner,
        "publicKey" => public_key
      })

    verify(payload, public_key, signature)
  end

  def verify_reauth_signature(challenge, agent_id, public_key, signature) do
    payload = Jason.encode!(%{"challenge" => challenge, "agentId" => agent_id})

    verify(payload, public_key, signature)
  end

  defp verify(payload, public_key, signature) do
    with {:ok, public_key_raw} <- Base64Url.decode(public_key),
         {:ok, signature_raw} <- Base64Url.decode(signature),
         true <- :crypto.verify(:eddsa, :none, payload, signature_raw, [public_key_raw, :ed25519]) do
      :ok
    else
      false -> {:error, :signature_invalid}
      :error -> {:error, :signature_invalid}
      _ -> {:error, :signature_invalid}
    end
  end
end

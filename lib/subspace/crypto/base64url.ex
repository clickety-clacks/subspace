defmodule Subspace.Crypto.Base64Url do
  @moduledoc false

  def encode(binary) when is_binary(binary) do
    Base.url_encode64(binary, padding: false)
  end

  def decode(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> :error
    end
  end
end

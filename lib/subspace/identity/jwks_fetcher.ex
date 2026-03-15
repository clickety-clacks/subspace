defmodule Subspace.Identity.JwksFetcher do
  @moduledoc false

  @callback fetch(String.t()) :: {:ok, map() | binary()} | {:error, :identity_unavailable}
end

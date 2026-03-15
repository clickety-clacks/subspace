defmodule Subspace.Identity.JwksHttpFetcher do
  @moduledoc false

  @behaviour Subspace.Identity.JwksFetcher

  alias Req.Response

  @impl true
  def fetch(url) when is_binary(url) do
    case Req.get(url: url) do
      {:ok, %Response{status: 200, body: body}} -> {:ok, body}
      _ -> {:error, :identity_unavailable}
    end
  end
end

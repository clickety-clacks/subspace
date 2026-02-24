defmodule Subspace.Repo do
  use Ecto.Repo,
    otp_app: :subspace,
    adapter: Ecto.Adapters.Postgres
end

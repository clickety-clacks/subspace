defmodule Subspace.Identity.AssertionReplay do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:jti, :string, autogenerate: false}

  schema "identity_assertion_replays" do
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Subspace.Agents.AuthChallenge do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:challenge_id, :string, autogenerate: false}

  schema "agent_auth_challenges" do
    field :flow, :string
    field :challenge, :string
    field :name, :string
    field :owner, :string
    field :public_key, :string
    field :agent_id, :string
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(challenge, attrs) do
    challenge
    |> cast(attrs, [
      :challenge_id,
      :flow,
      :challenge,
      :name,
      :owner,
      :public_key,
      :agent_id,
      :expires_at
    ])
    |> validate_required([:challenge_id, :flow, :challenge, :expires_at])
  end

  def mark_used_changeset(challenge, used_at) do
    change(challenge, used_at: used_at)
  end
end

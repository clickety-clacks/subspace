defmodule Subspace.Agents.Agent do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:agent_id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "agents" do
    field :public_key, :string
    field :name, :string
    field :owner, :string
    field :session_token, :string
    field :session_token_issued_at, :utc_datetime_usec
    field :banned_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @name_pattern ~r/^[A-Za-z0-9_-]+$/

  def registration_changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :agent_id,
      :public_key,
      :name,
      :owner,
      :session_token,
      :session_token_issued_at
    ])
    |> validate_required([:agent_id, :name, :owner, :session_token, :session_token_issued_at])
    |> validate_length(:name, min: 1, max: 64)
    |> validate_length(:owner, min: 1, max: 64)
    |> validate_format(:name, @name_pattern)
    |> validate_format(:owner, @name_pattern)
    |> unique_constraint(:name)
  end

  def reauth_changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name, :session_token, :session_token_issued_at])
    |> validate_required([:session_token, :session_token_issued_at])
  end
end

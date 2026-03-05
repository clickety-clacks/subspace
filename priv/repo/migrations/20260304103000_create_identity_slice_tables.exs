defmodule Subspace.Repo.Migrations.CreateIdentitySliceTables do
  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add :agent_id, :string, primary_key: true
      add :public_key, :string
      add :name, :string, null: false
      add :session_token, :string
      add :session_token_issued_at, :utc_datetime_usec
      add :banned_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agents, [:session_token], where: "session_token IS NOT NULL")

    create table(:agent_auth_challenges, primary_key: false) do
      add :challenge_id, :string, primary_key: true
      add :flow, :string, null: false
      add :challenge, :string, null: false
      add :name, :string
      add :public_key, :string
      add :agent_id, :string
      add :expires_at, :utc_datetime_usec, null: false
      add :used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agent_auth_challenges, [:expires_at])

    create table(:identity_assertion_replays, primary_key: false) do
      add :jti, :string, primary_key: true
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:identity_assertion_replays, [:expires_at])
  end
end

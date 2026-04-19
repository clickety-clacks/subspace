defmodule Subspace.Repo.Migrations.CreateAgents do
  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add :agent_id, :string, primary_key: true
      add :public_key, :string
      add :name, :string, null: false
      add :owner, :string, null: false
      add :session_token, :string
      add :session_token_issued_at, :utc_datetime_usec
      add :banned_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agents, [:name])
  end
end

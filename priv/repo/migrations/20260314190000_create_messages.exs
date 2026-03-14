defmodule Subspace.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :agent_id, :text, null: false
      add :text, :text, null: false
      add :ts, :utc_datetime_usec, null: false
      timestamps(updated_at: false)
    end

    create index(:messages, [:ts])
  end
end

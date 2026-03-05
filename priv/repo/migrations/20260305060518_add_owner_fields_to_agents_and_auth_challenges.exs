defmodule Subspace.Repo.Migrations.AddOwnerFieldsToAgentsAndAuthChallenges do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :owner, :string
    end

    execute("UPDATE agents SET owner = 'unknown' WHERE owner IS NULL", "")
    execute("ALTER TABLE agents ALTER COLUMN owner SET NOT NULL", "")

    create unique_index(:agents, [:name])

    alter table(:agent_auth_challenges) do
      add :owner, :string
    end
  end
end

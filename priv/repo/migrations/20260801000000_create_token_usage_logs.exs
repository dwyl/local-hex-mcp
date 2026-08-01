defmodule StdioMcp.Repo.Migrations.CreateTokenUsageLogs do
  use Ecto.Migration

  def change do
    create table(:token_usage_logs) do
      add :model, :string, null: false
      add :type, :string, null: false
      add :prompt_tokens, :integer, default: 0
      add :completion_tokens, :integer, default: 0
      add :total_tokens, :integer, default: 0

      timestamps(updated_at: false)
    end

    create index(:token_usage_logs, [:model])
    create index(:token_usage_logs, [:inserted_at])
  end
end

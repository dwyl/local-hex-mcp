defmodule StdioMcp.Repo.Migrations.CreateKnowledgeDecisions do
  use Ecto.Migration

  def change do
    create table(:knowledge_decisions) do
      add(:request_id, :string, null: false)
      add(:status, :string, null: false, default: "processing")
      add(:action, :string)
      add(:strategy, :string)
      add(:target_id, :integer)
      add(:top_similarity, :float)
      add(:detail, :text)
      add(:submitted_text, :text)

      timestamps()
    end

    create(unique_index(:knowledge_decisions, [:request_id]))
    create(index(:knowledge_decisions, [:inserted_at]))
  end
end

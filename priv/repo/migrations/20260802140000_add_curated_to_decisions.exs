defmodule StdioMcp.Repo.Migrations.AddCuratedToDecisions do
  use Ecto.Migration

  @moduledoc """
  Records whether a submission actually reached the curator.

  `top_similarity` was already stored for every submission, including those that
  never reached the LLM because no neighbour cleared the similarity floor. But
  both kinds of outcome were written as `action = "created"` with no strategy,
  so they could not be told apart — which makes the floor unmeasurable: you
  cannot ask "how many curator calls ended in create anyway?" (floor too low)
  or "how near the floor were the short-circuits?" (floor too high).
  """

  def change do
    alter table(:knowledge_decisions) do
      add(:curated, :boolean, default: false, null: false)
    end
  end
end

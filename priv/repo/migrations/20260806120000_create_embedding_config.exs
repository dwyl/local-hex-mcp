defmodule StdioMcp.Repo.Migrations.CreateEmbeddingConfig do
  use Ecto.Migration

  @moduledoc """
  Records which embedding model built the index.

  Nothing did, before this. `package_docs.embedding` is a TEXT column holding a
  JSON array, so vectors of any dimension write successfully and a model change
  needs no schema change — which is exactly why `anubis_mcp` sat at 1536
  dimensions (codestral-embed) while every query embedded at 1024
  (mistral-embed) and nothing anywhere said so. sqlite-vec refused the pair,
  `Docs.Search.run_query/4` rescued the error, and the search answered from FTS
  alone: the vector arm was dead for that package for days and the only symptom
  was results that looked badly ranked.

  One row, because the index has one answer to "what built this". A model change
  is not a migration in the schema sense and cannot be — a 1024-dimension and a
  1536-dimension index are different vector spaces, with no conversion between
  them. Switching models means re-embedding every row, and the point of this
  table is to make the system able to *say* that rather than discover it as a
  rescued exception.
  """

  def change do
    create table(:embedding_config, primary_key: false) do
      add(:id, :integer, primary_key: true)
      add(:model, :string, null: false)
      add(:dims, :integer, null: false)

      timestamps()
    end

    # The singleton is an invariant of the data, not a convention callers are
    # trusted to follow — the same reasoning that puts the FTS sync in triggers
    # rather than in every writer.
    execute(
      """
      CREATE TRIGGER embedding_config_singleton BEFORE INSERT ON embedding_config
      WHEN NEW.id <> 1
      BEGIN
        SELECT RAISE(ABORT, 'embedding_config holds exactly one row (id = 1)');
      END;
      """,
      "DROP TRIGGER IF EXISTS embedding_config_singleton;"
    )
  end
end

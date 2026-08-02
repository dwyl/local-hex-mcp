defmodule StdioMcp.Repo.Migrations.AddFtsUpdateTriggers do
  use Ecto.Migration

  @moduledoc """
  Adds the missing AFTER UPDATE triggers for both external-content FTS5 indexes.

  `knowledge_fts` and `package_docs_fts` are declared with `content='...'`, so
  reading a column from the FTS table reads through to the base table and always
  agrees with it. The inverted index is separate, and only the AFTER INSERT and
  AFTER DELETE triggers existed — nothing maintained it on UPDATE.

  Two consequences, both observed:

    * Search silently missed any text added by an update. A term the curator
      added to an existing row matched zero rows until the index was rebuilt.
    * `DELETE` failed outright with "database disk image is malformed": the
      delete trigger asks FTS5 to remove tokens for the row's *current* content,
      which was never indexed, so the deletion of a knowledge entry raised.

  The migration rebuilds both indexes to discard the stale state before
  installing the triggers.
  """

  def up do
    execute("INSERT INTO knowledge_fts(knowledge_fts) VALUES('rebuild')")
    execute("INSERT INTO package_docs_fts(package_docs_fts) VALUES('rebuild')")

    execute("""
    CREATE TRIGGER IF NOT EXISTS knowledge_au AFTER UPDATE ON knowledge BEGIN
      INSERT INTO knowledge_fts(knowledge_fts, rowid, title, content)
      VALUES ('delete', old.id, old.title, old.content);
      INSERT INTO knowledge_fts(rowid, title, content)
      VALUES (new.id, new.title, new.content);
    END
    """)

    execute("""
    CREATE TRIGGER IF NOT EXISTS package_docs_au AFTER UPDATE ON package_docs BEGIN
      INSERT INTO package_docs_fts(package_docs_fts, rowid, package, version, module, signature, content)
      VALUES ('delete', old.id, old.package, old.version, old.module, old.signature, old.content);
      INSERT INTO package_docs_fts(rowid, package, version, module, signature, content)
      VALUES (new.id, new.package, new.version, new.module, new.signature, new.content);
    END
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS knowledge_au")
    execute("DROP TRIGGER IF EXISTS package_docs_au")
  end
end

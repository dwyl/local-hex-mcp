defmodule StdioMcp.Repo.Migrations.CreateTables do
  use Ecto.Migration

  def change do
    create table(:package_docs) do
      add :package, :string, null: false
      add :version, :string, null: false
      add :doc_type, :string, null: false
      add :module, :string
      add :function, :string
      add :signature, :string
      add :content, :text
      add :code_snippet, :text
      add :hexdocs_url, :string
      add :embedding, :text

      timestamps()
    end

    create index(:package_docs, [:package, :version])
    create index(:package_docs, [:module])

    execute """
    CREATE VIRTUAL TABLE IF NOT EXISTS package_docs_fts USING fts5(
      package,
      version,
      module,
      signature,
      content,
      content='package_docs',
      content_rowid='id'
    );
    """

    execute """
    CREATE TRIGGER IF NOT EXISTS package_docs_ai AFTER INSERT ON package_docs BEGIN
      INSERT INTO package_docs_fts(rowid, package, version, module, signature, content)
      VALUES (new.id, new.package, new.version, new.module, new.signature, new.content);
    END;
    """

    execute """
    CREATE TRIGGER IF NOT EXISTS package_docs_ad AFTER DELETE ON package_docs BEGIN
      INSERT INTO package_docs_fts(package_docs_fts, rowid, package, version, module, signature, content)
      VALUES ('delete', old.id, old.package, old.version, old.module, old.signature, old.content);
    END;
    """

    create table(:knowledge) do
      add :title, :string, null: false
      add :kind, :string, null: false, default: "learning"
      add :content, :text, null: false
      add :outdated, :boolean, default: false
      add :metadata, :map, default: "{}"
      add :embedding, :text

      timestamps()
    end

    create index(:knowledge, [:kind])
    create index(:knowledge, [:outdated])

    execute """
    CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_fts USING fts5(
      title,
      content,
      content='knowledge',
      content_rowid='id'
    );
    """

    execute """
    CREATE TRIGGER IF NOT EXISTS knowledge_ai AFTER INSERT ON knowledge BEGIN
      INSERT INTO knowledge_fts(rowid, title, content)
      VALUES (new.id, new.title, new.content);
    END;
    """

    execute """
    CREATE TRIGGER IF NOT EXISTS knowledge_ad AFTER DELETE ON knowledge BEGIN
      INSERT INTO knowledge_fts(knowledge_fts, rowid, title, content)
      VALUES ('delete', old.id, old.title, old.content);
    END;
    """
  end
end

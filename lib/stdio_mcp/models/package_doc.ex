defmodule StdioMcp.PackageDoc do
  use Ecto.Schema
  import Ecto.Changeset

  schema "package_docs" do
    field :package, :string
    field :version, :string
    field :doc_type, :string
    field :module, :string
    field :function, :string
    field :signature, :string
    field :content, :string
    field :code_snippet, :string
    field :hexdocs_url, :string
    field :embedding, :string

    timestamps()
  end

  def changeset(package_doc, attrs) do
    package_doc
    |> cast(attrs, [
      :package,
      :version,
      :doc_type,
      :module,
      :function,
      :signature,
      :content,
      :code_snippet,
      :hexdocs_url,
      :embedding
    ])
    |> validate_required([:package, :version, :doc_type])
  end
end

defmodule StdioMcp.PackageDoc do
  use Ecto.Schema
  import Ecto.Changeset

  @typedoc """
  One indexed documentation chunk.

  `embedding` is a JSON array as text rather than a float list: sqlite-vec reads
  either a BLOB or JSON, and `vec_distance_cosine/2` parses it per query.

  `source_url` is `nil` for guides and for packages whose docs config sets no
  source URL — see `StdioMcp.Docs.TarballIngestion.source_index/1`.
  """
  @type t :: %__MODULE__{
          package: String.t(),
          version: String.t(),
          doc_type: String.t(),
          module: String.t() | nil,
          function: String.t() | nil,
          signature: String.t() | nil,
          content: String.t() | nil,
          code_snippet: String.t() | nil,
          hexdocs_url: String.t() | nil,
          source_url: String.t() | nil,
          embedding: String.t() | nil
        }

  schema "package_docs" do
    field(:package, :string)
    field(:version, :string)
    field(:doc_type, :string)
    field(:module, :string)
    field(:function, :string)
    field(:signature, :string)
    field(:content, :string)
    field(:code_snippet, :string)
    field(:hexdocs_url, :string)
    field(:source_url, :string)
    field(:embedding, :string)

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
      :source_url,
      :embedding
    ])
    |> validate_required([:package, :version, :doc_type])
  end
end

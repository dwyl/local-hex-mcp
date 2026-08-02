defmodule StdioMcp.Knowledge do
  use Ecto.Schema
  import Ecto.Changeset

  alias StdioMcp.Knowledge.Vocabulary

  schema "knowledge" do
    field(:title, :string)
    field(:kind, :string)
    field(:content, :string)
    field(:outdated, :boolean, default: false)
    field(:metadata, :map, default: %{})
    field(:embedding, :string)

    timestamps()
  end

  def changeset(knowledge, attrs) do
    knowledge
    |> cast(attrs, [:title, :kind, :content, :outdated, :metadata, :embedding])
    |> validate_required([:title, :kind, :content])
    |> validate_inclusion(:kind, Vocabulary.kinds(),
      message: "must be one of: #{Enum.join(Vocabulary.kinds(), ", ")}"
    )
    |> update_change(:metadata, &clean_metadata/1)
  end

  # `domain` is no longer part of the taxonomy: it duplicated what `stack` and
  # `package` already record, and every row collapsed into the single value
  # "code". The `kind` default was removed for the same reason "learning" was
  # dropped from the vocabulary — a default is how one value comes to hold
  # every row.
  defp clean_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.drop([:domain, "domain"])
    |> normalize_stack()
  end

  defp clean_metadata(metadata), do: metadata

  defp normalize_stack(metadata) do
    case fetch_stack(metadata) do
      :error -> metadata
      {:ok, key, tags} -> Map.put(metadata, key, Vocabulary.normalize_tags(tags))
    end
  end

  defp fetch_stack(metadata) do
    cond do
      is_list(metadata[:stack]) -> {:ok, :stack, metadata[:stack]}
      is_list(metadata["stack"]) -> {:ok, "stack", metadata["stack"]}
      true -> :error
    end
  end
end

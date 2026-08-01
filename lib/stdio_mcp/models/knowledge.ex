defmodule StdioMcp.Knowledge do
  use Ecto.Schema
  import Ecto.Changeset

  schema "knowledge" do
    field :title, :string
    field :kind, :string, default: "learning"
    field :content, :string
    field :outdated, :boolean, default: false
    field :metadata, :map, default: %{}
    field :embedding, :string

    timestamps()
  end

  def changeset(knowledge, attrs) do
    knowledge
    |> cast(attrs, [:title, :kind, :content, :outdated, :metadata, :embedding])
    |> validate_required([:title, :kind, :content])
  end
end

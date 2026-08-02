defmodule StdioMcp.Knowledge.Decision do
  @moduledoc """
  Audit record of what the curator actually did with a `remember` submission.

  Without this, `remember` was indistinguishable from a no-op: it replied
  `%{accepted: true, status: "processing"}` before the supervised task ran, and
  a `discard` returned an `:ok` tuple logged under "Saved". A submission could
  be dropped as a near-duplicate, or appended onto an unrelated entry, and the
  caller saw the same reply as a successful create.

  Each submission gets a `request_id` the caller can look up.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(processing applied failed)

  schema "knowledge_decisions" do
    field(:request_id, :string)
    field(:status, :string, default: "processing")
    field(:action, :string)
    field(:strategy, :string)
    field(:target_id, :integer)
    field(:top_similarity, :float)
    field(:detail, :string)
    field(:submitted_text, :string)
    field(:curated, :boolean, default: false)

    timestamps()
  end

  @fields ~w(request_id status action strategy target_id top_similarity detail submitted_text curated)a

  def changeset(decision \\ %__MODULE__{}, attrs) do
    decision
    |> cast(attrs, @fields)
    |> validate_required([:request_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:request_id)
  end
end

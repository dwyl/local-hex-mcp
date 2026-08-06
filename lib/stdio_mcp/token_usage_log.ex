defmodule StdioMcp.TokenUsageLog do
  use Ecto.Schema
  import Ecto.Changeset

  schema "token_usage_logs" do
    field(:model, :string)
    field(:type, :string)
    field(:prompt_tokens, :integer, default: 0)
    field(:completion_tokens, :integer, default: 0)
    field(:total_tokens, :integer, default: 0)

    timestamps(updated_at: false)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:model, :type, :prompt_tokens, :completion_tokens, :total_tokens])
    |> validate_required([:model, :type])
  end
end

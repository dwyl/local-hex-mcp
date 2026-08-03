defmodule StdioMcp.Knowledge.Vocabulary do
  @moduledoc """
  Single source of truth for the knowledge base taxonomy.

  Three consumers previously restated the vocabulary independently — the
  structuring prompt, the `recall` tool schema, and the changeset validation —
  with nothing forcing them to agree. They drifted: `recall` advertised filter
  values the writer never emitted, so every filtered search returned nothing.

  Everything is now derived from `kinds/0`. Adding or removing a kind here
  updates the prompt, the tool description, and the validation together.

  There is deliberately no generic bucket. A `learning`-style catch-all
  collapses the taxonomy — every entry qualifies, so the model always picks it
  and the filter stops discriminating.
  """

  @kinds ~w(pain_point pattern decision package_note)

  @descriptions %{
    "pain_point" => "something broke: symptom, root cause, and fix",
    "pattern" => "the way to do X correctly, for use when writing new code",
    "decision" => "chose X over Y for reason Z, for use when revisiting a choice",
    "package_note" => "a library at a given version behaves unexpectedly"
  }

  @doc "The allowed `kind` values."
  def kinds, do: @kinds

  @doc """
  Renders the kinds with their meanings as a single line, for the `description`
  of a JSON-schema field.

  The `enum` constrains which values are legal but says nothing about what they
  mean, and the choice between them is a judgement the model cannot make from
  the names alone. Carrying the meanings in the schema keeps that guidance next
  to the constraint instead of duplicated in the prompt.
  """
  def kinds_for_schema_description do
    "Which kind of entry this is — " <>
      Enum.map_join(@kinds, "; ", fn kind -> "#{kind} = #{@descriptions[kind]}" end) <> "."
  end

  @doc "Renders the kinds for the `recall` tool's field description."
  def kinds_for_schema, do: "Optional filter by kind: " <> Enum.join(@kinds, ", ")

  @doc """
  Normalizes a stack tag so filtering works.

  Tags arrive from an LLM and vary in shape — `"claude code"` and
  `"claude-code"` both appeared for the same technology, which silently breaks
  the `stack` filter since it matches exactly.

  Underscore is the canonical separator because tags are frequently Hex package
  names, which use it. That keeps a tag and the `package` field spelling the
  same library identically (`anubis_mcp`, not `anubis_mcp` beside `anubis-mcp`).
  """
  def normalize_tag(tag) when is_binary(tag) do
    tag
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s\-]+/, "_")
  end

  def normalize_tag(tag), do: tag

  def normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_tag/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def normalize_tags(_), do: []

  @doc """
  Falls back to a kind when the model returns something outside the vocabulary.

  Derived from the fields present rather than defaulting to one value: a
  constant fallback is how the previous `learning` sink came to hold every row.
  """
  def infer_kind(metadata) when is_map(metadata) do
    meta = Map.new(metadata, fn {k, v} -> {to_string(k), v} end)

    cond do
      present?(meta["symptom"]) or present?(meta["cause"]) -> "pain_point"
      present?(meta["package"]) and present?(meta["package_version"]) -> "package_note"
      true -> "pattern"
    end
  end

  def infer_kind(_), do: "pattern"

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true
end

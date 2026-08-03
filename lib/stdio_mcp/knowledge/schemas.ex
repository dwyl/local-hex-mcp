defmodule StdioMcp.Knowledge.Schemas do
  @moduledoc """
  JSON schemas describing the two structured responses the knowledge base asks
  the model for.

  These travel in the HTTP request as `response_format.json_schema.schema`, not
  in the prompt. That difference is not cosmetic: a shape described in the prompt
  is a request the model may ignore, whereas a schema on the request constrains
  decoding, so a response that violates it cannot be produced. The prompts keep
  only what a schema cannot express — the reconciliation workflow, the similarity
  bands, and the domain rules.

  ## Property order matters

  Constrained decoding emits fields in the order the schema declares them, so
  `reasoning` must come first for it to be deliberation rather than a
  justification written after the action was already chosen. A plain Elixir map
  cannot express that: its key order is neither insertion order nor stable
  between runs. Hence `Jason.OrderedObject`.

  ## Why every field is required

  Strict mode disallows conditional constructs (`if`/`then`, `oneOf`), so a
  decision that is really a tagged union — `discard` carries nothing, `update`
  carries an id and strategy — has to be expressed as one flat object with every
  property present and `null` where inapplicable. The conditions therefore live
  in each field's `description` and are advisory: callers still have to validate,
  which is why an unusable `id` falls back to creating a new entry.
  """

  alias StdioMcp.Knowledge.Vocabulary

  @doc "Schema for the curator's reconciliation decision, including the entry fields."
  def curation, do: object(curation_properties())

  @doc """
  Schema for structuring a submission that never reached the curator.

  Only used on the short-circuit path, where no neighbour cleared the similarity
  floor: when the curator does run it returns these fields itself, so the two
  calls are mutually exclusive and a submission costs one chat call either way.
  """
  def structuring, do: object(structuring_properties())

  # `required` is derived from the property list rather than written out
  # separately. Strict mode demands that every property appear in `required`, and
  # maintaining the two by hand let them drift: a name in one and not the other
  # is rejected by the API with an opaque "Invalid structured output syntax".
  defp object(properties) do
    %{
      type: "object",
      properties: %Jason.OrderedObject{values: properties},
      required: Enum.map(properties, fn {name, _spec} -> name end),
      additionalProperties: false
    }
  end

  defp curation_properties do
    [
      {"reasoning",
       %{
         type: "string",
         description:
           "Work through STEP 1 (does the new learning contradict or supersede a neighbour?) " <>
             "and then STEP 2 (the similarity bands), and state the conclusion. " <>
             "Write this before deciding the action."
       }},
      {"action",
       %{
         type: "string",
         enum: ["create", "discard", "update", "deprecate"],
         description:
           "create = a genuinely new topic; discard = adds nothing over the neighbour; " <>
             "update = change an existing entry (see strategy); deprecate = the neighbour is wholly obsolete."
       }},
      {"id",
       %{
         type: ["integer", "null"],
         description:
           "ID of the existing entry being acted on. Required when action is update or deprecate; null otherwise."
       }},
      {"strategy",
       %{
         type: ["string", "null"],
         enum: ["append", "merge", "replace", nil],
         description:
           "How to update the target: append = keep the old content and add to it; " <>
             "merge = synthesise old and new into one; replace = the old content is factually wrong. " <>
             "Required when action is update; null otherwise."
       }},
      {"reason",
       %{
         type: ["string", "null"],
         description:
           "Why the entry is obsolete. Required when action is deprecate; null otherwise."
       }},
      {"content",
       %{
         type: ["string", "null"],
         description:
           "The final, self-contained entry text. Required when action is create or update; null otherwise. " <>
             ~s|Prose only — no JSON metadata blobs or "Last updated" footers.|
       }},
      {"title",
       %{
         type: ["string", "null"],
         description: "Short summary, max 80 characters. Null unless action is create or update."
       }},
      {"kind",
       %{
         type: ["string", "null"],
         enum: Vocabulary.kinds() ++ [nil],
         description:
           Vocabulary.kinds_for_schema_description() <> " Null unless action is create or update."
       }},
      {"stack",
       %{
         type: ["array", "null"],
         items: %{type: "string"},
         description: stack_description() <> " Null unless action is create or update."
       }}
    ] ++ entry_fields()
  end

  defp structuring_properties do
    [
      {"title", %{type: "string", description: "Short summary, max 80 characters."}},
      {"kind",
       %{
         type: "string",
         enum: Vocabulary.kinds(),
         description:
           Vocabulary.kinds_for_schema_description() <>
             " Choose the closest match; there is deliberately no generic option."
       }},
      {"stack", %{type: "array", items: %{type: "string"}, description: stack_description()}}
    ] ++ entry_fields()
  end

  # Shared between both schemas so the two cannot drift apart.
  defp entry_fields do
    [
      {"symptom",
       %{type: ["string", "null"], description: "The error or behaviour observed, or null."}},
      {"cause", %{type: ["string", "null"], description: "The root cause, or null."}},
      {"fix", %{type: ["string", "null"], description: "How it was resolved, or null."}},
      {"package", %{type: ["string", "null"], description: "Hex.pm package name, or null."}},
      {"package_version",
       %{
         type: ["string", "null"],
         description: ~s|Version or constraint such as "~> 0.3", or null.|
       }},
      {"repo",
       %{type: ["string", "null"], description: ~s|GitHub repo such as "org/project", or null.|}}
    ]
  end

  defp stack_description do
    ~s|Technologies involved, lowercase with underscores (e.g. ["elixir", "postgres", "anubis_mcp"]).|
  end
end

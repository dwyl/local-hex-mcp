defmodule StdioMcp.Memory do
  @moduledoc """
  SQLite knowledge base storage with full multi-stage LLM curation pipeline (remember/recall).
  """
  import Ecto.Query, only: [from: 2]
  import SqliteVec.Ecto.Query
  alias StdioMcp.AI.Client
  alias StdioMcp.Knowledge
  alias StdioMcp.Knowledge.Decision
  alias StdioMcp.Knowledge.Schemas
  alias StdioMcp.Knowledge.Vocabulary
  alias StdioMcp.Repo
  require Logger

  # Below this, neighbours are not close enough to be worth a curator call.
  @similarity_threshold 0.7
  # Above this, a submission adding no new facts is a duplicate.
  @duplicate_threshold 0.9

  # How many neighbours to retrieve as curation candidates. The decision target
  # has consistently been the nearest one; the second is carried only so the
  # curator can see when a submission spans two entries and should be merged.
  # Anything beyond that has never changed an outcome and is pure prompt cost.
  @neighbor_limit 2

  # Only the nearest neighbour is rendered in full. The discard rule turns on
  # whether the submission "contains no fact absent from the neighbour", which
  # cannot be judged from an excerpt — so the likely target keeps its complete
  # text, while the runner-up is summarised.
  @excerpt_chars 400

  # -- Public API --

  def search(query_text, opts \\ []) when is_binary(query_text) do
    limit = Keyword.get(opts, :limit, 5)
    kind = Keyword.get(opts, :kind)
    package = Keyword.get(opts, :package)

    base_query = from(k in Knowledge, where: k.outdated == false)

    base_query =
      if kind && kind != "" do
        from(k in base_query, where: k.kind == ^kind)
      else
        base_query
      end

    base_query =
      if package && package != "" do
        from(k in base_query,
          where: fragment("json_extract(?, '$.package') = ?", k.metadata, ^package)
        )
      else
        base_query
      end

    run_fts_knowledge(base_query, query_text, limit)
  end

  def process_remember(text, request_id \\ nil) do
    if Client.memory_enabled?() do
      with {:ok, embedding} <- Client.embed(text),
           neighbors <- search_by_vector(embedding, limit: @neighbor_limit),
           {:ok, decision} <- decide(text, neighbors),
           :ok <- log_decision(decision, neighbors),
           {:ok, result} <- apply_decision(decision) do
        Logger.info("[Memory] #{result.detail}")
        record_outcome(request_id, decision, neighbors, result)
      else
        {:error, reason} ->
          Logger.error("[Memory] Remember failed: #{inspect(reason)}")
          record_failure(request_id, reason)
      end
    else
      {:error, :memory_disabled}
    end
  end

  # -- Decision audit trail --
  #
  # Without this, `remember` was indistinguishable from a no-op: it replied
  # "processing" before the supervised task ran, and a discard returned an :ok
  # tuple logged as "Saved". A submission dropped as a near-duplicate looked
  # exactly like a successful create.

  def open_decision(request_id, submitted_text) do
    %Decision{}
    |> Decision.changeset(%{
      request_id: request_id,
      status: "processing",
      submitted_text: submitted_text
    })
    |> Repo.insert()
  end

  def close_decision(request_id, attrs) do
    case Repo.get_by(Decision, request_id: request_id) do
      nil -> {:error, :not_found}
      decision -> decision |> Decision.changeset(attrs) |> Repo.update()
    end
  end

  def get_decision(request_id) do
    case Repo.get_by(Decision, request_id: request_id) do
      nil -> {:error, :not_found}
      decision -> {:ok, decision}
    end
  end

  defp record_outcome(nil, _decision, _neighbors, _result), do: :ok

  defp record_outcome(request_id, decision, neighbors, result) do
    close_decision(request_id, %{
      status: "applied",
      action: result.action,
      strategy: Map.get(decision, :strategy),
      target_id: Map.get(result, :id),
      top_similarity: top_similarity(neighbors),
      curated: Map.get(decision, :curated, false),
      detail: result.detail
    })

    :ok
  end

  defp record_failure(nil, _reason), do: :ok

  defp record_failure(request_id, reason) do
    close_decision(request_id, %{
      status: "failed",
      detail: "remember failed: #{inspect(reason)}"
    })

    :ok
  end

  defp top_similarity([]), do: 0.0

  defp top_similarity(neighbors) do
    neighbors |> Enum.map(fn n -> 1.0 - n.distance end) |> Enum.max(fn -> 0.0 end)
  end

  @doc """
  Deletes every knowledge entry and decision record.

  Intended for the taxonomy reset: stored `kind` and `domain` values predate the
  current vocabulary, and embeddings were computed from a prompt that no longer
  matches.
  """
  def reset! do
    {decisions, _} = Repo.delete_all(Decision)
    {entries, _} = Repo.delete_all(Knowledge)
    Logger.info("[Memory] reset: #{entries} entries, #{decisions} decisions deleted")
    %{entries: entries, decisions: decisions}
  end

  # -- Storage Functions --

  def save(attrs) when is_map(attrs) do
    %Knowledge{}
    |> Knowledge.changeset(attrs)
    |> Repo.insert()
  end

  def update(id, attrs) when is_integer(id) and is_map(attrs) do
    case Repo.get(Knowledge, id) do
      nil -> {:error, :not_found}
      entry -> entry |> Knowledge.changeset(attrs) |> Repo.update()
    end
  end

  def deprecate(id, reason \\ nil) when is_integer(id) do
    case Repo.get(Knowledge, id) do
      nil ->
        {:error, :not_found}

      entry ->
        meta = Map.put(entry.metadata || %{}, "deprecated_reason", reason || "Deprecated")
        entry |> Knowledge.changeset(%{outdated: true, metadata: meta}) |> Repo.update()
    end
  end

  # -- FTS & Vector Search --

  defp run_fts_knowledge(base_query, query_text, limit) do
    sanitized_query =
      query_text
      |> String.replace(~r/[^\w\s]/, " ")
      |> String.split()
      |> Enum.reject(&(&1 in ~w(how to define a tool with the package version)))
      |> Enum.join(" OR ")

    fts_query =
      if sanitized_query != "" do
        from(k in base_query,
          join: fts in "knowledge_fts",
          on: k.id == fts.rowid,
          where: fragment("knowledge_fts MATCH ?", ^sanitized_query),
          order_by: [asc: fragment("rank")],
          limit: ^limit
        )
      else
        base_query
      end

    case Repo.all(fts_query) do
      [] ->
        like = "%#{query_text}%"

        from(k in base_query,
          where: ilike(k.content, ^like) or ilike(k.title, ^like),
          limit: ^limit
        )
        |> Repo.all()

      results ->
        results
    end
  rescue
    e ->
      Logger.warning("[Memory] Knowledge FTS failed: #{Exception.message(e)}")
      []
  end

  defp search_by_vector(embedding, opts) when is_list(embedding) do
    limit = Keyword.get(opts, :limit, 3)
    query_json = Jason.encode!(embedding)

    from(k in Knowledge,
      where: k.outdated == false and not is_nil(k.embedding),
      select: {k, vec_distance_cosine(k.embedding, ^query_json)},
      order_by: [asc: vec_distance_cosine(k.embedding, ^query_json)],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.map(fn {entry, distance} -> Map.put(entry, :distance, distance) end)
  end

  defp search_by_vector(_embedding, _opts), do: []

  # -- LLM Curation Pipeline (decide / ask_mistral / structure_text) --

  # `curated: false` marks a create that never reached the LLM because nothing
  # cleared the floor. Recording it separately is what makes the floor itself
  # measurable rather than a guess.
  defp decide(text, []) do
    with {:ok, structured} <- structure_text(text) do
      {:ok, %{action: "create", content: text, structured: structured, curated: false}}
    end
  end

  defp decide(text, neighbors) do
    close = Enum.filter(neighbors, fn n -> 1.0 - n.distance >= @similarity_threshold end)

    if close == [] do
      decide(text, [])
    else
      with {:ok, decision} <- ask_mistral(text, close) do
        {:ok, Map.put(decision, :curated, true)}
      end
    end
  end

  defp ask_mistral(text, neighbors) do
    existing =
      neighbors
      |> Enum.sort_by(& &1.distance)
      |> Enum.with_index()
      |> Enum.map_join("\n\n", fn {n, i} -> render_neighbor(n, i) end)

    prompt = """
    You are a knowledge base curator. A new learning is being saved. Similar entries already exist.

    Goal: Determine the appropriate reconciliation action to maintain a clean, non-redundant and accurate knowledge base.

    Today's date: #{Date.utc_today()}.


    ### RECONCILIATION WORKFLOW (Evaluate in order)

    Work through the two steps in order. STEP 1 takes precedence over STEP 2.

    STEP 1 — Does the new learning CONTRADICT or SUPERSEDE any existing entry?
    A correction is by construction almost identical to the thing it corrects, so it
    will show a very high similarity. High similarity is therefore NOT evidence that a
    correction is a duplicate. If the new learning states that something in an existing
    entry is now wrong, renamed, moved, removed or otherwise out of date:
      - the old entry is wrong but the topic still exists  -> "replace"
      - the old entry is wholly obsolete                   -> "deprecate"
    Never answer "discard" for a correction, no matter how high the similarity.

    STEP 2 — Otherwise, apply the similarity bands:
      - similarity > #{@duplicate_threshold} AND the new learning contains no fact absent from the neighbour -> "discard"
      - similarity between #{@similarity_threshold} and #{@duplicate_threshold}, new learning adds detail, edge cases or version notes -> "append"
      - similarity between #{@similarity_threshold} and #{@duplicate_threshold}, both hold partial truths that belong together -> "merge"
      - the topic is genuinely different despite embedding proximity -> "create"

    ### Additional domain rules:
    - **Package versions**: a fix for library v1 may not apply to v2. If versions differ, prefer "create" to keep both.
    - **API changes**: if behaviour changed between versions, the old entry is still valid for its version — prefer "append" or "create".
    - **Preserve prior learnings**: outside of STEP 1, never drop information. "append" and "merge" must carry over the existing content.
    - **Preserve structure**: if either the new learning or the neighbour states a symptom, a root cause or a fix, the content you return must still state them. Merging must not silently drop these.
    - **One topic per entry**: if the new learning is about a different subject than the neighbour, choose "create" rather than attaching it to an unrelated entry.

    The response shape is fixed by the schema attached to this request; every field
    carries its own description there. Reason through the workflow above before
    committing to an action.

    NEW LEARNING:
    #{text}

    EXISTING ENTRIES (each shows its measured similarity to the new learning):
    #{existing}
    """

    case Client.chat([%{role: "user", content: prompt}], [],
           model: Client.large_model(),
           json_schema: Schemas.curation(),
           schema_name: "curation_decision"
         ) do
      {:ok, %{"content" => content}} -> parse_decision(content, text)
      {:error, _} = err -> err
    end
  end

  # Nearest neighbour: full text, because the discard rule turns on whether the
  # submission contains a fact absent from it, which an excerpt cannot answer.
  # The label stays neutral: calling it the "likely target" biased the curator
  # towards attaching to it instead of creating a separate entry.
  defp render_neighbor(n, 0) do
    """
    [ID: #{n.id}] #{n.title}
    Similarity to the new learning: #{format_similarity(n)}  (full content)
    Kind: #{n.kind}
    Content: #{n.content}
    Metadata: #{Jason.encode!(n.metadata)}
    Last updated: #{Map.get(n, :updated_at, "unknown")}
    """
  end

  # Runner-up: excerpt only. It is present so the curator can recognise a
  # submission that spans two entries and belongs merged, which needs the gist
  # rather than the full body.
  defp render_neighbor(n, _rank) do
    """
    [ID: #{n.id}] #{n.title}
    Similarity to the new learning: #{format_similarity(n)}  (excerpt only)
    Kind: #{n.kind}
    Content (first #{@excerpt_chars} chars): #{excerpt(n.content)}
    Metadata: #{Jason.encode!(n.metadata)}
    """
  end

  defp excerpt(content) when is_binary(content) do
    if String.length(content) > @excerpt_chars do
      String.slice(content, 0, @excerpt_chars) <> " […truncated]"
    else
      content
    end
  end

  defp excerpt(content), do: content

  defp format_similarity(%{distance: distance}) when is_float(distance) do
    "#{Float.round((1.0 - distance) * 100, 1)}%"
  end

  defp format_similarity(_), do: "unknown"

  defp parse_decision(content, original_text) do
    json = clean_json(content)

    case Jason.decode(json) do
      {:ok, %{"action" => "discard"}} ->
        {:ok, %{action: "discard"}}

      {:ok, %{"action" => "update", "id" => id, "content" => merged} = p} ->
        structured = build_structured_from_parsed(merged, p)
        resolve_update(parse_id(id), merged, p["strategy"] || "merge", structured)

      {:ok, %{"action" => "deprecate", "id" => id} = p} ->
        resolve_deprecate(parse_id(id), p["reason"], original_text)

      {:ok, %{"action" => "create", "content" => new_c} = p} ->
        structured = build_structured_from_parsed(new_c, p)
        {:ok, %{action: "create", content: new_c, structured: structured}}

      _ ->
        {:ok, %{action: "create", content: original_text}}
    end
  end

  defp build_structured_from_parsed(text, parsed) when is_map(parsed) do
    metadata = extract_metadata(parsed)

    %{
      kind: normalize_kind(parsed["kind"], metadata),
      title: parsed["title"] || String.slice(text, 0, 80),
      content: text,
      metadata: metadata
    }
  end

  defp resolve_update({:ok, id}, merged, strategy, structured) do
    {:ok,
     %{action: "update", id: id, content: merged, strategy: strategy, structured: structured}}
  end

  defp resolve_update(:error, merged, _strategy, structured) do
    {:ok, %{action: "create", content: merged, structured: structured}}
  end

  defp resolve_deprecate({:ok, id}, reason, original_text) do
    {:ok, %{action: "deprecate", id: id, reason: reason, content: original_text}}
  end

  defp resolve_deprecate(:error, _reason, original_text) do
    {:ok, %{action: "create", content: original_text}}
  end

  # `update/2` and `deprecate/2` guard on `is_integer`, and the model returns the
  # id as a string often enough to matter.
  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  # A discard is a deliberate no-op, but it is still an outcome the caller has
  # to be able to distinguish from a save.
  defp apply_decision(%{action: "discard"}) do
    {:ok, %{action: "discarded", detail: "discarded (too similar to an existing entry)"}}
  end

  # Deprecation only flips a flag, so it needs neither structuring nor a fresh
  # embedding.
  defp apply_decision(%{action: "deprecate", id: id} = decision) do
    reason = Map.get(decision, :reason)

    case deprecate(id, reason) do
      {:ok, entry} ->
        {:ok,
         %{
           action: "deprecated",
           id: entry.id,
           title: entry.title,
           detail: "deprecated ##{entry.id} — #{entry.title}"
         }}

      {:error, reason} ->
        {:error, {:deprecate_failed, id, reason}}
    end
  end

  defp apply_decision(decision) do
    with {:ok, structured} <- fetch_or_structure_text(decision),
         {:ok, final_embedding} <- Client.embed(decision.content) do
      result = execute_decision(decision, structured, final_embedding)
      title = Map.get(result, :title, "n/a")
      {:ok, Map.put(result, :detail, "#{result.action} — #{title}")}
    end
  end

  defp fetch_or_structure_text(%{structured: structured}) when is_map(structured),
    do: {:ok, structured}

  defp fetch_or_structure_text(decision), do: structure_text(decision.content)

  defp execute_decision(%{action: "create"}, structured, embedding) do
    {:ok, entry} = save(Map.put(structured, :embedding, Jason.encode!(embedding)))
    %{action: "created", id: entry.id, title: entry.title}
  end

  defp execute_decision(%{action: "update", id: id}, structured, embedding) do
    attrs = Map.put(structured, :embedding, Jason.encode!(embedding))

    case update(id, attrs) do
      {:ok, entry} ->
        %{action: "updated", id: entry.id, title: entry.title}

      _ ->
        {:ok, entry} = save(attrs)
        %{action: "created (fallback)", id: entry.id, title: entry.title}
    end
  end

  defp structure_text(text) do
    prompt = """
    Extract the structured fields describing this technical learning. The response
    shape is fixed by the schema attached to this request and every field carries
    its own description there.

    Text: #{text}
    """

    case Client.chat([%{role: "user", content: prompt}], [],
           model: Client.small_model(),
           json_schema: Schemas.structuring(),
           schema_name: "structured_learning"
         ) do
      {:ok, %{"content" => content}} ->
        case Jason.decode(clean_json(content)) do
          {:ok, parsed} ->
            metadata = extract_metadata(parsed)

            {:ok,
             %{
               kind: normalize_kind(parsed["kind"], metadata),
               title: parsed["title"] || String.slice(text, 0, 80),
               content: text,
               metadata: metadata
             }}

          _ ->
            {:ok, fallback_structure(text)}
        end

      _ ->
        {:ok, fallback_structure(text)}
    end
  end

  # Only the named fields are kept. Storing the whole parsed response put
  # `title` and `kind` inside `metadata` too, which is how `metadata.kind` ended
  # up holding an object on some rows while the column held a string.
  defp extract_metadata(parsed) when is_map(parsed) do
    %{
      symptom: parsed["symptom"],
      cause: parsed["cause"],
      fix: parsed["fix"],
      stack: Vocabulary.normalize_tags(parsed["stack"] || []),
      package: parsed["package"],
      package_version: parsed["package_version"],
      repo: parsed["repo"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp extract_metadata(_), do: %{}

  defp fallback_structure(text) do
    %{
      kind: Vocabulary.infer_kind(%{}),
      title: String.slice(text, 0, 80),
      content: text,
      metadata: %{}
    }
  end

  defp normalize_kind(kind, metadata) when is_binary(kind) do
    if kind in Vocabulary.kinds() do
      kind
    else
      # Inferred from the fields present rather than defaulting to a constant.
      # A fixed fallback is how "learning" came to hold every row in this table.
      Vocabulary.infer_kind(metadata)
    end
  end

  defp normalize_kind(_kind, metadata), do: Vocabulary.infer_kind(metadata)

  defp clean_json(c) do
    c |> String.replace(~r/^```json\n?/, "") |> String.replace(~r/\n?```$/, "") |> String.trim()
  end

  defp log_decision(%{action: action}, _neighbors) do
    Logger.info("[Memory decision] #{action}")
    :ok
  end
end

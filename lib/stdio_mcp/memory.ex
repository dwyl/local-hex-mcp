defmodule StdioMcp.Memory do
  @moduledoc """
  SQLite knowledge base storage with full multi-stage LLM curation pipeline (remember/recall).
  """
  import Ecto.Query, only: [from: 2]
  import SqliteVec.Ecto.Query
  alias StdioMcp.AI.Client
  alias StdioMcp.Docs.EmbeddingConfig
  alias StdioMcp.Docs.Fusion
  alias StdioMcp.Knowledge
  alias StdioMcp.Knowledge.Decision
  alias StdioMcp.Knowledge.Schemas
  alias StdioMcp.Knowledge.Vocabulary
  alias StdioMcp.Repo
  require Logger

  # Below this, neighbours are not close enough to be worth a curator call.
  # Above this, a submission goes to the LLM to decide create/append/merge/replace;
  # below it, `decide/2` creates directly and marks the entry `curated: false`.
  #
  # Was 0.7, which is not a meaningful "these might be the same" line for
  # mistral-embed on prose. Measured over 91 pairs of *known-distinct* entries:
  # median 0.738, max 0.943, and 73% cleared 0.70 — so the gate fired on three
  # quarters of all pairs, none of them duplicates, and every submission reached
  # the large model. The top pair scored 0.943 for two entries deliberately
  # written about different bugs; cosine on prose measures topic, and a base that
  # is all "Elixir debugging findings" is one topic.
  #
  #   threshold   non-duplicate pairs clearing it
  #     0.70        73%
  #     0.80        19%
  #     0.90         2%
  #
  # 0.80 rather than 0.90 because the two errors are not symmetric: a threshold
  # too low costs one model call and the LLM then correctly answers "create",
  # while a threshold too high means a real duplicate never reaches the LLM and
  # is stored forever. Cheap and self-correcting beats permanent.
  #
  # Calibrated against 14 entries in one topic. Re-measure as the base
  # diversifies — and note a themed batch is self-similar by construction, since
  # `remember` curates sequentially and later entries see earlier ones already
  # stored.
  @similarity_threshold 0.8
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

  @memory_search_schema NimbleOptions.new!(
                          limit: [
                            type: :pos_integer,
                            default: 5,
                            doc: "Maximum knowledge search results to return."
                          ],
                          kind: [
                            type: {:or, [:string, nil]},
                            default: nil,
                            doc: "Kind filter."
                          ],
                          package: [
                            type: {:or, [:string, nil]},
                            default: nil,
                            doc: "Package filter."
                          ]
                        )

  def search(query_text, opts \\ []) when is_binary(query_text) do
    validated = NimbleOptions.validate!(opts, @memory_search_schema)
    limit = validated[:limit]

    base_query =
      from(k in Knowledge, where: k.outdated == false)
      |> scope_kind(presence(validated[:kind]))
      |> scope_package(presence(validated[:package]))

    case query_embedding(query_text) do
      {:ok, embedding} -> hybrid_knowledge(base_query, query_text, embedding, limit)
      :unavailable -> run_fts_knowledge(base_query, query_text, limit)
    end
  end

  # Each filter is "apply it or don't", which is two function heads rather than
  # an `if` that has to name the untouched query in its else branch. Rebinding
  # `base_query` three times also made the order look significant when it is not.
  defp scope_kind(query, nil), do: query
  defp scope_kind(query, kind), do: from(k in query, where: k.kind == ^kind)

  defp scope_package(query, nil), do: query

  defp scope_package(query, package) do
    from(k in query, where: fragment("json_extract(?, '$.package') = ?", k.metadata, ^package))
  end

  # Blank and non-binary both collapse to nil, so the scopes above test presence
  # with a plain nil match instead of repeating `x && x != ""`. Same helper as
  # `StdioMcp.Docs.Search` — five lines duplicated in preference to a utility
  # module that would attract everything else with nowhere else to live.
  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  @spec process_remember(binary(), any()) :: :ok | {:error, :memory_disabled}
  def process_remember(text, request_id \\ nil) do
    if Client.memory_enabled?() do
      with {:ok, embedding} <- Client.embed(text),
           neighbors <- neighbors(text, embedding, @neighbor_limit),
           {:ok, decision} <- decide(text, neighbors),
           :ok <- log_decision(decision, neighbors),
           {:ok, result} <- apply_decision(decision) do
        Logger.info("[Memory] #{result.detail}")
        :ok = record_outcome(request_id, decision, neighbors, result)
      else
        {:error, reason} ->
          Logger.error("[Memory] Remember failed: #{inspect(reason)}")
          :ok = record_failure(request_id, reason)
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

  @spec open_decision(String.t(), String.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def open_decision(request_id, submitted_text) do
    %Decision{}
    |> Decision.changeset(%{
      request_id: request_id,
      status: "processing",
      submitted_text: submitted_text
    })
    |> Repo.insert()
  end

  @spec close_decision(binary(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def close_decision(request_id, attrs) do
    case Repo.get_by(Decision, request_id: request_id) do
      nil -> {:error, :not_found}
      decision -> decision |> Decision.changeset(attrs) |> Repo.update()
    end
  end

  @spec get_decision(String.t()) :: {:error, :not_found} | {:ok, any()}
  def get_decision(request_id) do
    case Repo.get_by(Decision, request_id: request_id) do
      nil -> {:error, :not_found}
      decision -> {:ok, decision}
    end
  end

  @spec record_outcome(any(), term(), term(), map()) :: :ok
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

  @spec record_failure(any(), term()) :: :ok
  defp record_failure(nil, _reason), do: :ok

  defp record_failure(request_id, reason) do
    close_decision(request_id, %{
      status: "failed",
      detail: "remember failed: #{inspect(reason)}"
    })

    :ok
  end

  @spec top_similarity(term()) :: float()
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

  @spec update(term(), term()) :: {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def update(id, attrs) when is_integer(id) and is_map(attrs) do
    case Repo.get(Knowledge, id) do
      nil -> {:error, :not_found}
      entry -> entry |> Knowledge.changeset(attrs) |> Repo.update()
    end
  end

  @spec deprecate(integer(), term()) :: {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
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
  #
  # Both halves of this subsystem used to run one arm. `recall` read with FTS5
  # alone; `remember` found its deduplication candidates with cosine alone —
  # exactly inverted, and both blind in the way the other was not. The docs
  # pipeline had already measured what that costs: the union of the two arms is
  # worth 0.07 of recall@10 over either alone, because they fail differently. A
  # keyword arm cannot reach a question phrased in words the entry never uses; a
  # bi-encoder ranks a shared literal identifier no better than a paraphrase.
  #
  # Fusion is used for **candidate recall only**, never for ordering — the same
  # role it plays in `Docs.Search`, and the reason `remember` re-sorts by cosine
  # below.

  # Shallow on purpose. RRF scores agreement, so depth lets mediocre-but-agreed
  # rows outrank a strong single-arm hit; `Docs.Fusion` documents the measurement.
  # A knowledge base is small, so this is mostly about the shape being right as it
  # grows.
  defp arm_depth(limit), do: max(limit * 3, 10)

  # `nil` rather than an error tuple for every unavailable case, because the
  # caller's response is identical for all of them: fall back to keyword search.
  # No key is the ordinary case — `recall` is expected to work offline — and a
  # model mismatch means the stored vectors are not comparable with a fresh query
  # embedding, which `Docs.Search` handles the same way.
  defp query_embedding(text) do
    with :ok <- embedding_usable(),
         {:ok, embedding} <- Client.embed(text) do
      {:ok, embedding}
    else
      _ -> :unavailable
    end
  end

  defp embedding_usable do
    case EmbeddingConfig.check() do
      :ok -> :ok
      :unset -> :ok
      {:mismatch, _stored, _current} -> :mismatch
    end
  end

  defp hybrid_knowledge(base_query, query_text, embedding, limit) do
    depth = arm_depth(limit)

    case Fusion.rrf(
           [fts_ids(base_query, query_text, depth), vector_ids(base_query, embedding, depth)],
           limit
         ) do
      # Both arms empty. `run_fts_knowledge/3` carries an `ilike` fallback for the
      # case where FTS tokenisation matches nothing, which is worth keeping.
      [] -> run_fts_knowledge(base_query, query_text, limit)
      ids -> hydrate(base_query, ids)
    end
  end

  # Scoped by `base_query` before the depth cut, so a `kind:` or `package:` filter
  # narrows what each arm ranks rather than being applied to an already-truncated
  # list — the same reason `Docs.Search` joins its arms to the scoped query.
  defp fts_ids(base_query, query_text, depth) do
    case sanitize(query_text) do
      "" ->
        []

      match ->
        from(k in base_query,
          join: fts in "knowledge_fts",
          on: k.id == fts.rowid,
          where: fragment("knowledge_fts MATCH ?", ^match),
          order_by: [asc: fragment("rank")],
          limit: ^depth,
          select: k.id
        )
        |> Repo.all()
    end
  rescue
    e ->
      Logger.warning("[Memory] knowledge FTS arm failed: #{Exception.message(e)}")
      []
  end

  defp vector_ids(base_query, embedding, depth) do
    query_json = Jason.encode!(embedding)

    from(k in base_query,
      where: not is_nil(k.embedding),
      order_by: [asc: vec_distance_cosine(k.embedding, ^query_json)],
      limit: ^depth,
      select: k.id
    )
    |> Repo.all()
  rescue
    e ->
      Logger.warning("[Memory] knowledge vector arm failed: #{Exception.message(e)}")
      []
  end

  # `id IN (…)` returns storage order, so the fused ranking has to be reimposed.
  defp hydrate(base_query, ids) do
    index =
      from(k in base_query, where: k.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(ids, fn id -> index |> Map.get(id) |> List.wrap() end)
  end

  # -- Deduplication candidates for `remember` --

  # Fusion widens the candidate set; cosine still orders it. `decide/2` renders
  # only the nearest neighbour in full and applies `@similarity_threshold` to a
  # distance, so a candidate the keyword arm found must carry a real distance and
  # must not displace a closer one just because both arms agreed on it. Re-sorting
  # after hydration keeps every downstream rule exactly as it was calibrated, and
  # confines the change to *which* entries get considered.
  defp neighbors(text, embedding, limit) do
    case embedding_usable() do
      :mismatch ->
        skip_neighbors()

      :ok ->
        base = from(k in Knowledge, where: k.outdated == false and not is_nil(k.embedding))
        depth = arm_depth(limit)

        [fts_ids(base, text, depth), vector_ids(base, embedding, depth)]
        |> Fusion.rrf(depth)
        |> with_distance(embedding)
        |> Enum.sort_by(& &1.distance)
        |> Enum.take(limit)
    end
  end

  # Returning nothing rather than an error: with no neighbours `decide/2` creates
  # a new entry, which can store a duplicate that a later pass merges. Trusting a
  # distance computed across two embedding models can merge into the *wrong* entry
  # or discard a real learning, and neither is recoverable.
  defp skip_neighbors do
    %{model: stored} = EmbeddingConfig.get()

    Logger.warning(
      "[Memory] knowledge entries were embedded with '#{stored}' but the server is " <>
        "configured for '#{Client.embed_model()}' — skipping neighbour search, so this " <>
        "entry is stored without deduplication. Run `mix docs.reindex` to re-embed."
    )

    []
  end

  # Every candidate gets a real cosine distance, including one only the keyword
  # arm found — otherwise the threshold could not be applied to it at all.
  defp with_distance(ids, embedding) do
    query_json = Jason.encode!(embedding)

    index =
      from(k in Knowledge,
        where: k.id in ^ids,
        select: {k, vec_distance_cosine(k.embedding, ^query_json)}
      )
      |> Repo.all()
      |> Map.new(fn {entry, distance} -> {entry.id, Map.put(entry, :distance, distance)} end)

    Enum.flat_map(ids, fn id -> index |> Map.get(id) |> List.wrap() end)
  end

  defp sanitize(query_text) do
    query_text
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split()
    |> Enum.reject(&(&1 in ~w(how to define a tool with the package version)))
    |> Enum.join(" OR ")
  end

  defp run_fts_knowledge(base_query, query_text, limit) do
    sanitized_query = sanitize(query_text)

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

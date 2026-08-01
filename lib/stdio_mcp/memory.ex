defmodule StdioMcp.Memory do
  @moduledoc """
  SQLite knowledge base storage with full multi-stage LLM curation pipeline (remember/recall).
  """
  import Ecto.Query, only: [from: 2]
  import SqliteVec.Ecto.Query
  alias StdioMcp.{Knowledge, Repo}
  alias StdioMcp.AI.Client
  require Logger

  @similarity_threshold 0.7

  # -- Public API --

  def search(query_text, opts \\ []) when is_binary(query_text) do
    limit = Keyword.get(opts, :limit, 5)
    kind = Keyword.get(opts, :kind)
    domain = Keyword.get(opts, :domain)
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

    base_query =
      if domain && domain != "" do
        from(k in base_query,
          where: fragment("json_extract(?, '$.domain') = ?", k.metadata, ^domain)
        )
      else
        base_query
      end

    run_fts_knowledge(base_query, query_text, limit)
  end

  def process_remember(text) do
    if Client.memory_enabled?() do
      with {:ok, embedding} <- Client.embed(text),
           neighbors <- search_by_vector(embedding, limit: 3),
           {:ok, decision} <- decide(text, neighbors),
           :ok <- log_decision(decision, neighbors),
           {:ok, result} <- apply_decision(decision) do
        Logger.info("[Memory] Saved: #{result}")
      else
        {:error, reason} ->
          Logger.error("[Memory] Remember failed: #{inspect(reason)}")
      end
    else
      {:error, :memory_disabled}
    end
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

  defp decide(text, []) do
    {:ok, %{action: "create", content: text}}
  end

  defp decide(text, neighbors) do
    close = Enum.filter(neighbors, fn n -> 1.0 - n.distance >= @similarity_threshold end)

    if close == [] do
      {:ok, %{action: "create", content: text}}
    else
      ask_mistral(text, close)
    end
  end

  defp ask_mistral(text, neighbors) do
    existing =
      Enum.map_join(neighbors, "\n\n", fn n ->
        """
        [ID: #{n.id}] #{n.title}
        Kind: #{n.kind}
        Content: #{n.content}
        Metadata: #{Jason.encode!(n.metadata)}
        """
      end)

    prompt = """
    You are a knowledge base curator. A new learning is being saved. Similar entries already exist.
    Today's date: #{Date.utc_today()}.

    NEW LEARNING:
    #{text}

    EXISTING ENTRIES:
    #{existing}

    Decide what to do:
    1. {"action": "create", "content": "<text>"} — genuinely new topic
    2. {"action": "discard"} — identical entry
    3. {"action": "update", "id": <id>, "strategy": "append", "content": "<old + new>"} — extends existing topic
    4. {"action": "update", "id": <id>, "strategy": "merge", "content": "<combined>"} — synthesize overlapping topic
    5. {"action": "update", "id": <id>, "strategy": "replace", "content": "<new>"} — old info was wrong/superseded
    6. {"action": "deprecate", "id": <id>, "reason": "<why>"} — soft delete

    Return ONLY valid JSON.
    """

    case Client.chat([%{role: "user", content: prompt}], [], model: Client.large_model()) do
      {:ok, %{"content" => content}} -> parse_decision(content, text)
      {:error, _} = err -> err
    end
  end

  defp parse_decision(content, original_text) do
    json = clean_json(content)

    case Jason.decode(json) do
      {:ok, %{"action" => "discard"}} ->
        {:ok, %{action: "discard"}}

      {:ok, %{"action" => "update", "id" => id, "content" => merged} = p} ->
        {:ok, %{action: "update", id: id, content: merged, strategy: p["strategy"] || "merge"}}

      {:ok, %{"action" => "create", "content" => new_c}} ->
        {:ok, %{action: "create", content: new_c}}

      _ ->
        {:ok, %{action: "create", content: original_text}}
    end
  end

  defp apply_decision(%{action: "discard"}) do
    {:ok, "discarded (too similar)"}
  end

  defp apply_decision(decision) do
    with {:ok, structured} <- structure_text(decision.content),
         {:ok, final_embedding} <- Client.embed(decision.content) do
      result = execute_decision(decision, structured, final_embedding)
      {:ok, "#{result.action} — #{result.title}"}
    end
  end

  defp execute_decision(%{action: "create"}, structured, embedding) do
    {:ok, entry} = save(Map.put(structured, :embedding, Jason.encode!(embedding)))
    %{action: "created", id: entry.id, title: entry.title}
  end

  defp execute_decision(%{action: "deprecate", id: id} = dec, _struct, _emb) do
    case deprecate(id, dec[:reason]) do
      {:ok, entry} -> %{action: "deprecated", id: entry.id, title: entry.title}
      _ -> %{action: "error", id: id}
    end
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
    Extract structured fields from this technical learning. Return ONLY valid JSON:
    - "title": short summary (max 80 chars)
    - "kind": "learning", "pain_point", "decision", "pattern", "package_note"
    - "domain": "deploy", "config", "code", "debug"
    - "stack": list of lowercased technologies (e.g. ["elixir", "phoenix", "caddy"])
    - "symptom": error observed (or null)
    - "cause": root cause (or null)
    - "fix": resolution (or null)
    - "package": hex.pm package name (or null)

    Text: #{text}
    """

    case Client.chat([%{role: "user", content: prompt}], [], model: Client.small_model()) do
      {:ok, %{"content" => content}} ->
        case Jason.decode(clean_json(content)) do
          {:ok, parsed} ->
            {:ok,
             %{
               kind: normalize_kind(parsed["kind"]),
               title: parsed["title"] || String.slice(text, 0, 80),
               content: text,
               metadata: parsed
             }}

          _ ->
            {:ok,
             %{kind: "learning", title: String.slice(text, 0, 80), content: text, metadata: %{}}}
        end

      _ ->
        {:ok, %{kind: "learning", title: String.slice(text, 0, 80), content: text, metadata: %{}}}
    end
  end

  @allowed_kinds ~w(learning pain_point decision pattern package_note)

  defp normalize_kind(kind) when is_binary(kind) and kind in @allowed_kinds, do: kind

  defp normalize_kind(kind) when is_binary(kind) do
    case kind do
      "bug" -> "pain_point"
      "caveat" -> "pain_point"
      "workaround" -> "pain_point"
      "tip" -> "learning"
      "info" -> "learning"
      _ -> "learning"
    end
  end

  defp normalize_kind(_), do: "learning"

  defp clean_json(c) do
    c |> String.replace(~r/^```json\n?/, "") |> String.replace(~r/\n?```$/, "") |> String.trim()
  end

  defp log_decision(%{action: action}, _neighbors) do
    Logger.info("[Memory decision] #{action}")
    :ok
  end
end

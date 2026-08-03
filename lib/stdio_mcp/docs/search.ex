defmodule StdioMcp.Docs.Search do
  @moduledoc "Hybrid FTS5 + sqlite-vec vector search over package docs."
  import Ecto.Query
  import SqliteVec.Ecto.Query
  alias StdioMcp.Docs.IngestionJob
  alias StdioMcp.Docs.TarballIngestion
  alias StdioMcp.PackageDoc
  alias StdioMcp.Repo
  require Logger

  def search(query, opts \\ []) when is_binary(query) do
    package = Keyword.get(opts, :package)
    version = Keyword.get(opts, :version)
    refresh = Keyword.get(opts, :refresh, false)
    examples_only = Keyword.get(opts, :include_examples_only, false)
    embedding = Keyword.get(opts, :embedding)
    limit = Keyword.get(opts, :limit, 10)

    {notices, resolved_version} = ensure_ingested(package, version, refresh, query)

    base_query = from(d in PackageDoc)

    base_query =
      if package && package != "" do
        from(d in base_query, where: d.package == ^package)
      else
        base_query
      end

    # Prefer the version ingestion actually resolved: asking for "latest" and
    # filtering on the literal string matches nothing, and without a filter
    # results from several stored versions get mixed together.
    version_filter = resolved_version || version

    base_query =
      if is_binary(version_filter) and version_filter != "" and version_filter != "latest" do
        from(d in base_query, where: d.version == ^version_filter)
      else
        base_query
      end

    base_query =
      if examples_only do
        from(d in base_query, where: not is_nil(d.code_snippet) and d.code_snippet != "")
      else
        base_query
      end

    {results, query_notices} = run_query(base_query, query, embedding, limit)
    {results, notices ++ query_notices}
  end

  # Hybrid: FTS5 candidates + vector re-ranking
  defp run_query(base_query, query, vec, limit) when is_list(vec) or is_binary(vec) do
    vec_param = if is_list(vec), do: Jason.encode!(vec), else: vec
    sanitized = sanitize_fts(query)

    results =
      if sanitized != "" do
        # The MATCH has to sit in a standalone query against the FTS table.
        # Written as `left_join ... where: MATCH(...) or ...` SQLite rejects it
        # with "unable to use function MATCH in the requested context" — every
        # call raised, the rescue below swallowed it, and the search silently
        # degraded to FTS-only, never using the stored embeddings.
        fts_ids =
          from(f in "package_docs_fts",
            where: fragment("package_docs_fts MATCH ?", ^sanitized),
            select: f.rowid
          )

        # This was `d.id in subquery(fts_ids) or (not is_nil(d.embedding) ...)`,
        # which is two bugs in one clause. "FTS matches OR anything embedded"
        # reduces to "anything embedded", so the FTS candidates were never
        # actually narrowing anything — the re-ranking ran over the whole
        # package. And the left side admitted rows with a nil embedding, which
        # then reached vec_distance_cosine and raised, so a single legacy nil row
        # took down every vector search for that package.
        case Repo.all(hybrid_query(base_query, fts_ids, vec_param, limit)) do
          # Keyword terms that match nothing should not mean "no results" —
          # fall back to ranking the package by vector distance alone.
          [] -> Repo.all(vector_query(base_query, vec_param, limit))
          hits -> hits
        end
      else
        # No useful FTS terms — pure vector search on rows with embeddings
        Repo.all(vector_query(base_query, vec_param, limit))
      end

    {results, []}
  rescue
    e ->
      Logger.warning("[Docs.Search] hybrid query failed: #{Exception.message(e)}")
      # Fall back to FTS-only
      run_query(base_query, query, nil, limit)
  end

  # FTS5-only (no embedding available)
  defp run_query(base_query, query, _vec, limit) do
    sanitized = sanitize_fts(query)

    results =
      if sanitized != "" do
        from(d in base_query,
          join: fts in "package_docs_fts",
          on: d.id == fts.rowid,
          where: fragment("package_docs_fts MATCH ?", ^sanitized),
          order_by: [asc: fragment("rank")],
          limit: ^limit
        )
        |> Repo.all()
      else
        from(d in base_query, limit: ^limit) |> Repo.all()
      end

    {results, []}
  rescue
    e ->
      Logger.warning("[Docs.Search] FTS query failed: #{Exception.message(e)}")
      {[], ["Search query failed: #{Exception.message(e)}"]}
  end

  # Rows without an embedding are excluded everywhere a cosine ordering is used:
  # sqlite-vec raises on a NULL vector rather than sorting it last.
  defp vector_query(base_query, vec_param, limit) do
    from(d in base_query,
      where: not is_nil(d.embedding) and d.embedding != "",
      order_by: [asc: vec_distance_cosine(d.embedding, ^vec_param)],
      limit: ^limit
    )
  end

  defp hybrid_query(base_query, fts_ids, vec_param, limit) do
    from(d in vector_query(base_query, vec_param, limit),
      where: d.id in subquery(fts_ids)
    )
  end

  # Sanitize query for FTS5: strip punctuation, join with OR
  defp sanitize_fts(query) do
    query
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split()
    |> Enum.join(" OR ")
  end

  defp ensure_ingested(package, version, refresh, _query) do
    cond do
      is_nil(package) or package == "" -> {[], nil}
      refresh -> maybe_auto_ingest(package, true, version)
      true -> maybe_auto_ingest(package, false, version)
    end
  end

  defp maybe_auto_ingest(package, refresh, version) do
    target_version = normalize_version(version)

    if not refresh and already_ingested?(package, target_version) do
      {incomplete_notices(package, target_version), nil}
    else
      Logger.info("[Docs.Search] auto-ingesting docs for package: #{package} (#{target_version})")
      run_ingestion(package, target_version)
    end
  end

  defp normalize_version(version) when is_binary(version) and version != "", do: version
  defp normalize_version(_version), do: "latest"

  # Docs are stored under the resolved version, so "latest" can never match a
  # stored value; the presence of rows for the package is the real test.
  defp doc_scope(package, "latest"), do: from(d in PackageDoc, where: d.package == ^package)

  defp doc_scope(package, version),
    do: from(d in PackageDoc, where: d.package == ^package and d.version == ^version)

  defp already_ingested?(package, version), do: Repo.exists?(doc_scope(package, version))

  # A row with a nil embedding is invisible to vector search while still
  # counting as indexed, so this damage is otherwise undetectable from a search.
  #
  # Treating it as "not ingested" and repairing automatically was tried and is
  # worse: a package that *cannot* be re-embedded — rate limit, missing key —
  # re-downloads the tarball and fails again on every single search, never
  # converging. Naming the damage costs one COUNT and leaves the expensive
  # repair to an explicit `refresh: true`.
  defp incomplete_notices(package, version) do
    scope = doc_scope(package, version)

    case Repo.aggregate(from(d in scope, where: is_nil(d.embedding)), :count) do
      0 ->
        []

      missing ->
        [
          "Docs for '#{package}' have #{missing} entries with no embedding — those are " <>
            "invisible to vector search. Pass refresh: true to re-ingest the package."
        ]
    end
  end

  # Tarball ingestion is one download plus embedding, so a large package runs to
  # ~45s. Waiting is what the caller wants — the whole point is to answer from a
  # *complete* ingestion — but the ceiling is not what the job needs, it is what
  # the transport allows. Anubis's session GenServer.call gives up at 30s
  # (observed: `session_call_failed, {:timeout, {GenServer, :call, [..., 30000]}}`),
  # so anything at or above that never returns a notice at all — the request just
  # dies. Staying under it is what makes the progress notice reachable, and the
  # retry-and-attach path the normal way a slow package completes.
  # 25s, not 30s: the whole 30s budget is the session call, and this wait is only
  # one part of what runs inside it — the query embedding happens before it and
  # the FTS/vector query after. Setting this to the ceiling itself guarantees the
  # request dies before the notice can be returned.
  #
  # Tunable via INGEST_TIMEOUT_MS (see config/runtime.exs); read at call time so
  # a restart is enough to pick up a new value.
  @default_ingest_timeout 25_000

  defp ingest_timeout do
    Application.get_env(:stdio_mcp, :ingest_timeout_ms, @default_ingest_timeout)
  end

  defp run_ingestion(package, target_version) do
    TarballIngestion
    |> IngestionJob.run(package, target_version, ingest_timeout(), fn ->
      TarballIngestion.ingest(package, target_version)
    end)
    |> handle_ingest_result(package)
  end

  # Ingestion reports success in two shapes: {:ok, count, version} and
  # {:ok, count}. Both are matched, plus a catch-all — matching only one of them
  # is how a successful ingest previously raised CaseClauseError *after* writing
  # the rows. Returning the resolved version lets the caller scope results to the
  # version that was just indexed.
  defp handle_ingest_result({:ok, {:ok, count, resolved_version}}, package) do
    {["Docs for '#{package}' v#{resolved_version} were just indexed (#{count} docs)."],
     resolved_version}
  end

  defp handle_ingest_result({:ok, {:ok, _count}}, package) do
    {["Docs for '#{package}' were just indexed."], nil}
  end

  defp handle_ingest_result({:ok, {:error, {:no_docs, ver}}}, package) do
    {["No docs published for '#{package}' v#{ver} and could not detect a served version."], nil}
  end

  defp handle_ingest_result({:ok, {:error, reason}}, package) do
    {["Ingestion failed for '#{package}': #{inspect(reason)}"], nil}
  end

  # Not a failure and not a lie: the job is still running, and saying how long it
  # has been going and what it is doing is what stops an impatient retry from
  # looking like nothing happened.
  # The retry instruction has to say "without refresh" explicitly. `refresh:
  # true` forces a new ingestion unconditionally, so a caller who repeats the
  # original arguments after this notice does not attach to the running job —
  # it re-downloads and re-embeds the entire package from scratch, competing
  # with the job already doing that work.
  defp handle_ingest_result({:timeout, progress}, package) do
    {[
       "Docs for '#{package}' are still being indexed (#{describe(progress)}). " <>
         "The job is still running — retry the same query shortly WITHOUT refresh: true " <>
         "to attach to it and get its result. Retrying with refresh: true restarts the " <>
         "whole ingestion instead."
     ], nil}
  end

  defp handle_ingest_result(other, package) do
    {["Ingestion for '#{package}' returned an unexpected result: #{inspect(other)}"], nil}
  end

  defp describe(%{stage: stage, elapsed_ms: ms}) when is_integer(ms) do
    "#{stage}, #{div(ms, 1000)}s elapsed"
  end

  defp describe(_progress), do: "in progress"
end

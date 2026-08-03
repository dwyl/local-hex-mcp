defmodule StdioMcp.Docs.Search do
  @moduledoc "Hybrid FTS5 + sqlite-vec vector search over package docs."
  import Ecto.Query
  import SqliteVec.Ecto.Query
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

        from(d in base_query,
          where: d.id in subquery(fts_ids) or (not is_nil(d.embedding) and d.embedding != ""),
          order_by: [asc: vec_distance_cosine(d.embedding, ^vec_param)],
          limit: ^limit
        )
        |> Repo.all()
      else
        # No useful FTS terms — pure vector search on rows with embeddings
        from(d in base_query,
          where: not is_nil(d.embedding) and d.embedding != "",
          order_by: [asc: vec_distance_cosine(d.embedding, ^vec_param)],
          limit: ^limit
        )
        |> Repo.all()
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
      {[], nil}
    else
      Logger.info("[Docs.Search] auto-ingesting docs for package: #{package} (#{target_version})")
      run_ingestion(package, target_version)
    end
  end

  defp normalize_version(version) when is_binary(version) and version != "", do: version
  defp normalize_version(_version), do: "latest"

  # Docs are stored under the resolved version, so "latest" can never match a
  # stored value; the presence of any row for the package is the real test.
  defp already_ingested?(package, "latest") do
    Repo.exists?(from(d in PackageDoc, where: d.package == ^package))
  end

  defp already_ingested?(package, version) do
    Repo.exists?(from(d in PackageDoc, where: d.package == ^package and d.version == ^version))
  end

  # Tarball ingestion is one download plus embedding, so a large package runs to
  # ~45s. The caller does not block that long: past this the task is detached and
  # the query returns a "try again shortly" notice that is now accurate.
  @ingest_timeout 20_000

  defp run_ingestion(package, target_version) do
    task =
      Task.Supervisor.async_nolink(StdioMcp.TaskSupervisor, fn ->
        TarballIngestion.ingest(package, target_version)
      end)

    # `Task.shutdown/1` would *kill* the task, so a package needing longer than
    # the timeout could never finish: every attempt was terminated at 15s and the
    # "still ingesting" notice was a lie. `Task.ignore/1` detaches instead, so the
    # work really does continue and a later query finds the rows.
    result = Task.yield(task, @ingest_timeout) || Task.ignore(task)
    handle_ingest_result(result, package)
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

  defp handle_ingest_result(nil, package) do
    {["Docs for '#{package}' still ingesting (large package) — try again shortly."], nil}
  end

  defp handle_ingest_result(other, package) do
    {["Ingestion for '#{package}' returned an unexpected result: #{inspect(other)}"], nil}
  end
end

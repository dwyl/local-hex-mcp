defmodule StdioMcp.Docs.Search do
  @moduledoc "Hybrid FTS5 + sqlite-vec vector search over package docs."
  import Ecto.Query
  import SqliteVec.Ecto.Query
  alias StdioMcp.Docs.IngestionWorker
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

    notices = ensure_ingested(package, version, refresh, query)

    base_query = from(d in PackageDoc)

    base_query =
      if package && package != "" do
        from(d in base_query, where: d.package == ^package)
      else
        base_query
      end

    version_filter = version

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
        # FTS5 match OR rows with embeddings, ranked by vector distance
        from(d in base_query,
          left_join: fts in "package_docs_fts",
          on: d.id == fts.rowid,
          where:
            fragment("package_docs_fts MATCH ?", ^sanitized) or
              (not is_nil(d.embedding) and d.embedding != ""),
          order_by: [
            asc: vec_distance_cosine(d.embedding, ^vec_param)
          ],
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
      is_nil(package) or package == "" ->
        []

      refresh ->
        maybe_auto_ingest(package, true, version)

      true ->
        maybe_auto_ingest(package, false, version)
    end
  end

  defp maybe_auto_ingest(package, refresh, version) do
    target_version = normalize_version(version)

    if not refresh and already_ingested?(package, target_version) do
      []
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

  defp run_ingestion(package, target_version) do
    task =
      Task.Supervisor.async_nolink(StdioMcp.TaskSupervisor, fn ->
        IngestionWorker.ingest(package, target_version)
      end)

    result = Task.yield(task, 15_000) || Task.shutdown(task)
    handle_ingest_result(result, package)
  end

  # `ingest/2` reports success in two shapes: {:ok, count, version} from the
  # search-data path and {:ok, count} from the single-page fallback. Only the
  # second was matched, so a successful ingest via the main path raised
  # CaseClauseError *after* writing the rows — the caller saw a failure for work
  # that had actually succeeded, and only a retry appeared to work.
  defp handle_ingest_result({:ok, {:ok, count, _version}}, package),
    do: log_ingested(count, package)

  defp handle_ingest_result({:ok, {:ok, count}}, package),
    do: log_ingested(count, package)

  defp handle_ingest_result({:ok, {:error, reason}}, package),
    do: ["Docs for '#{package}' ingestion issue: #{inspect(reason)}."]

  defp handle_ingest_result(nil, package),
    do: ["Docs for '#{package}' still ingesting — try again shortly."]

  defp handle_ingest_result(other, package),
    do: ["Docs for '#{package}' ingestion returned an unexpected result: #{inspect(other)}."]

  defp log_ingested(count, package) do
    Logger.info("[Docs.Search] Ingested #{count} docs for #{package}")
    []
  end
end

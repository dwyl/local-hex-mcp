defmodule StdioMcp.Docs.Search do
  @moduledoc "Hybrid FTS5 + sqlite-vec vector search over package docs."
  import Ecto.Query
  import SqliteVec.Ecto.Query
  alias StdioMcp.Docs.HexPackage
  alias StdioMcp.Docs.IngestionJob
  alias StdioMcp.Docs.RepairBudget
  alias StdioMcp.Docs.TarballIngestion
  alias StdioMcp.PackageDoc
  alias StdioMcp.Repo
  require Logger

  @typedoc "Human-readable messages returned alongside results."
  @type notices :: [String.t()]

  @typedoc """
  The version an ingestion actually resolved to. `nil` when the answer came from
  cache, because no resolution took place.
  """
  @type resolved_version :: String.t() | nil

  # Answering across every indexed package is worse than not answering. A query
  # naming a package we have never ingested still matches rows in unrelated
  # packages that share keywords — asking about `poolboy` returned
  # `GenMagic.Pool.Poolboy` and `Boruta.Oauth.Scopes.public/0`, with nothing in
  # the payload to say poolboy had never been looked up. A caller cannot tell
  # that apart from a real answer, so refuse rather than mislead.
  @no_package_notice "No package given, so no search was run. search_docs answers " <>
                       "within a single package: pass the Hex package name as " <>
                       "`package` (e.g. package: \"phoenix\"), which also triggers " <>
                       "ingestion when it is not indexed yet."

  @spec search(String.t(), keyword()) :: {[%StdioMcp.PackageDoc{}], notices()}
  def search(query, opts \\ []) when is_binary(query) do
    case opts |> Keyword.get(:package) |> presence() do
      nil -> {[], [@no_package_notice]}
      package -> search_package(query, package, opts)
    end
  end

  @spec search_package(String.t(), String.t(), keyword()) :: {[%StdioMcp.PackageDoc{}], notices()}
  defp search_package(query, package, opts) do
    # Normalised once, here, so `version` has a single meaning everywhere below.
    # Previously `nil` meant "latest" on the ingestion branch and "apply no
    # filter" on the query branch, which is how a cached search silently
    # interleaved every stored version of a package.
    version = opts |> Keyword.get(:version) |> presence() || "latest"

    refresh = Keyword.get(opts, :refresh, false)
    examples_only = Keyword.get(opts, :include_examples_only, false)
    embedding = Keyword.get(opts, :embedding)
    limit = Keyword.get(opts, :limit, 10)

    {notices, resolved_version} = ensure_ingested(package, version, refresh)

    base_query =
      from(d in PackageDoc)
      |> scope_package(package)
      |> scope_version(resolved_version || version)
      |> scope_examples(examples_only)

    {results, query_notices} = run_query(base_query, query, embedding, limit)
    {results, notices ++ query_notices}
  end

  defp scope_package(query, package), do: from(d in query, where: d.package == ^package)

  # Docs are stored under the version ingestion resolved, so "latest" is never a
  # stored value — as a filter it can only mean "no filter". An ingestion that
  # just ran reports its resolved version and takes precedence, which is what
  # scopes a first-time search to the version it just wrote.
  defp scope_version(query, "latest"), do: query
  defp scope_version(query, version), do: from(d in query, where: d.version == ^version)

  defp scope_examples(query, false), do: query

  defp scope_examples(query, true),
    do: from(d in query, where: not is_nil(d.code_snippet) and d.code_snippet != "")

  # Blank and non-binary both collapse to nil, so every caller below tests
  # presence with a plain nil check rather than repeating `x && x != ""`.
  @spec presence(term()) :: String.t() | nil
  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  # Hybrid: FTS5 candidates + vector re-ranking
  @spec run_query(Ecto.Query.t(), String.t(), list() | String.t() | nil, pos_integer()) ::
          {[%StdioMcp.PackageDoc{}], notices()}
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
  @spec sanitize_fts(String.t()) :: String.t()
  defp sanitize_fts(query) do
    query
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split()
    |> Enum.join(" OR ")
  end

  # Ingestion decision. `package` is a non-blank binary and `requested` is either
  # "latest" or a concrete version — `search/2` guarantees both.
  #
  # One version per package is the invariant, so this never has to choose between
  # stored versions; it decides whether what is stored is the version we want and
  # whether it is complete.
  @spec ensure_ingested(String.t(), String.t(), boolean()) :: {notices(), resolved_version()}

  # `refresh: true` is the escape hatch and overrides every rule below: resolve a
  # target and re-ingest it, whatever is stored.
  defp ensure_ingested(package, requested, true) do
    case resolve_target(package, requested) do
      {:ok, target, docs_url} ->
        Logger.info("[Docs.Search] refresh requested for #{package} (#{target})")
        ingest(package, target, docs_url)

      {:error, notices} ->
        {notices, nil}
    end
  end

  defp ensure_ingested(package, requested, false) do
    decide(package, requested, stored_version(package))
  end

  # Nothing stored: resolve and ingest.
  defp decide(package, requested, nil) do
    case resolve_target(package, requested) do
      {:ok, target, docs_url} -> ingest(package, target, docs_url)
      {:error, notices} -> {notices, nil}
    end
  end

  # An explicit version that is already the stored one needs no Hex lookup at
  # all: it demonstrably exists, because we ingested it. This is the fully-cached
  # path and it makes no network call.
  defp decide(package, stored, stored) do
    serve_or_repair(package, stored, nil)
  end

  defp decide(package, requested, stored) when requested != "latest" do
    Logger.info("[Docs.Search] switching #{package} from #{stored} to #{requested}")

    case resolve_target(package, requested) do
      {:ok, target, docs_url} -> ingest(package, target, docs_url)
      {:error, notices} -> {notices, nil}
    end
  end

  # "latest" with something already stored. The version this project actually
  # runs wins when the package is one of our dependencies — that is the version
  # the caller's code executes against, and it costs no request to learn.
  defp decide(package, "latest", stored) do
    case app_version(package) do
      ^stored -> serve_or_repair(package, stored, nil)
      _other -> compare_with_hex(package, stored)
    end
  end

  # A stored version that differs from the current release is reported, not
  # replaced. Auto-switching would make one unpinned search discard a pinned
  # version and force a full re-embed to get it back.
  defp compare_with_hex(package, stored) do
    case HexPackage.fetch(package) do
      {:ok, meta} ->
        case HexPackage.latest(meta) do
          ^stored ->
            serve_or_repair(package, stored, meta.docs_url)

          nil ->
            serve_or_repair(package, stored, meta.docs_url)

          newer ->
            {[version_notice(package, stored, newer)] ++ incomplete_notices(package, stored),
             stored}
        end

      {:error, _reason} ->
        # Hex unreachable: serve what we have rather than fail the search.
        serve_or_repair(package, stored, nil)
    end
  end

  # Complete data is served as-is. Incomplete data is worth re-ingesting, but
  # only within budget: repair was once unbounded and a package that could not be
  # re-embedded re-downloaded its tarball on every single search forever.
  defp serve_or_repair(package, version, docs_url) do
    case missing_embeddings(package, version) do
      0 ->
        RepairBudget.clear(package, version)
        {[], version}

      missing ->
        if RepairBudget.allow?(package, version) do
          Logger.info(
            "[Docs.Search] repairing #{package} #{version} (#{missing} rows unembedded)"
          )

          ingest(package, version, docs_url)
        else
          {[repair_exhausted_notice(package, version, missing)], version}
        end
    end
  end

  # Resolves what to ingest, and refuses a version Hex does not publish rather
  # than discovering it as a 404 on the tarball.
  @spec resolve_target(String.t(), String.t()) ::
          {:ok, String.t(), String.t() | nil} | {:error, notices()}
  defp resolve_target(package, requested) do
    case HexPackage.fetch(package) do
      {:ok, meta} -> target_from(meta, package, requested)
      {:error, :not_found} -> {:error, ["No such package on Hex: '#{package}'."]}
      {:error, reason} -> {:error, ["Could not reach Hex for '#{package}': #{inspect(reason)}."]}
    end
  end

  defp target_from(meta, package, "latest") do
    case app_version(package) || HexPackage.latest(meta) do
      nil -> {:error, ["Hex lists no releases for '#{package}'."]}
      target -> {:ok, target, meta.docs_url}
    end
  end

  defp target_from(meta, package, requested) do
    if HexPackage.published?(meta, requested) do
      {:ok, requested, meta.docs_url}
    else
      {:error, [unpublished_notice(package, requested, meta.versions)]}
    end
  end

  # Behind and ahead are different situations and must not read the same. The
  # stored version can be *newer* than the latest stable — a pre-release, like
  # boruta 3.0.0-beta.4 against a stable 2.3.8. Calling the stable "current"
  # there tells the reader they are stale when they are ahead, and the obvious
  # next action (refresh) silently downgrades them.
  defp version_notice(package, stored, latest) do
    case safe_compare(stored, latest) do
      :lt ->
        "Indexed '#{package}' is v#{stored}; v#{latest} is now the latest stable. " <>
          "Nothing was changed — pass refresh: true to move to v#{latest}."

      :gt ->
        "Indexed '#{package}' is v#{stored}, which is ahead of the latest stable " <>
          "v#{latest} (a pre-release). Nothing was changed. Keep using it as-is; " <>
          "refresh: true without a version would move you *back* to v#{latest}, so " <>
          "pass version: \"#{stored}\" if you refresh."

      _eq_or_unknown ->
        "Indexed '#{package}' is v#{stored}; Hex reports v#{latest}. Nothing was changed."
    end
  end

  # Hex versions are semver in practice but not guaranteed to parse, and a
  # comparison failure must not take down a search that was otherwise fine.
  defp safe_compare(a, b) do
    Version.compare(a, b)
  rescue
    Version.InvalidVersionError -> :unknown
  end

  defp unpublished_notice(package, requested, versions) do
    known = versions |> Enum.take(8) |> Enum.join(", ")

    "Version '#{requested}' is not published for '#{package}'. Recent releases: #{known}."
  end

  defp repair_exhausted_notice(package, version, missing) do
    "Docs for '#{package}' v#{version} have #{missing} entries with no embedding and " <>
      "#{RepairBudget.max_attempts()} repair attempts already failed — not retrying. " <>
      "Check the embedding API, then pass refresh: true."
  end

  # The version this project runs, when the package is one of its dependencies.
  # Local, free, and authoritative for the caller's own code. `to_existing_atom`
  # rather than `to_atom`: package names arrive from tool input and atoms are
  # never collected.
  @spec app_version(String.t()) :: String.t() | nil
  defp app_version(package) do
    case :application.get_key(String.to_existing_atom(package), :vsn) do
      {:ok, vsn} -> to_string(vsn)
      :undefined -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec stored_version(String.t()) :: String.t() | nil
  defp stored_version(package) do
    Repo.one(from(d in PackageDoc, where: d.package == ^package, select: d.version, limit: 1))
  end

  @spec missing_embeddings(String.t(), String.t()) :: non_neg_integer()
  defp missing_embeddings(package, version) do
    Repo.aggregate(
      from(d in PackageDoc,
        where: d.package == ^package and d.version == ^version and is_nil(d.embedding)
      ),
      :count
    )
  end

  defp ingest(package, version, docs_url) do
    RepairBudget.record_attempt(package, version)

    TarballIngestion
    |> IngestionJob.run(package, version, ingest_timeout(), fn ->
      TarballIngestion.ingest(package, version, docs_url)
    end)
    |> handle_ingest_result(package)
  end

  # A row with a nil embedding is invisible to vector search while still
  # counting as indexed, so this damage is otherwise undetectable from a search.
  # Used where repair is not attempted — the budget is spent, or the stored
  # version is not the one being compared against.
  @spec incomplete_notices(String.t(), String.t()) :: notices()
  defp incomplete_notices(package, version) do
    case missing_embeddings(package, version) do
      0 ->
        []

      missing ->
        [
          "Docs for '#{package}' v#{version} have #{missing} entries with no embedding — " <>
            "those are invisible to vector search. Pass refresh: true to re-ingest."
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

  # Ingestion reports success in two shapes: {:ok, count, version} and
  # {:ok, count}. Both are matched, plus a catch-all — matching only one of them
  # is how a successful ingest previously raised CaseClauseError *after* writing
  # the rows. Returning the resolved version lets the caller scope results to the
  # version that was just indexed.
  @spec handle_ingest_result(IngestionJob.outcome(), String.t()) ::
          {notices(), resolved_version()}
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

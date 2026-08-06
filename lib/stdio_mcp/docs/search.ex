defmodule StdioMcp.Docs.Search do
  @moduledoc "Hybrid FTS5 + sqlite-vec vector search over package docs."
  import Ecto.Query
  import SqliteVec.Ecto.Query
  alias StdioMcp.Docs.EmbeddingConfig
  alias StdioMcp.Docs.Fusion
  alias StdioMcp.Docs.HexPackage
  alias StdioMcp.Docs.IngestionJob
  alias StdioMcp.Docs.Lockfile
  alias StdioMcp.Docs.RepairBudget
  alias StdioMcp.Docs.TarballIngestion
  alias StdioMcp.Docs.QuerySanitizer
  alias StdioMcp.Docs.Reranker
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

  @search_schema NimbleOptions.new!(
    package: [
      type: {:or, [:string, :nil]},
      default: nil,
      doc: "Hex package name to search within."
    ],
    version: [
      type: {:or, [:string, :nil]},
      default: nil,
      doc: "Optional package version or 'latest'."
    ],
    refresh: [
      type: :boolean,
      default: false,
      doc: "Whether to force re-ingesting the package."
    ],
    include_examples_only: [
      type: :boolean,
      default: false,
      doc: "Filter results to only entries containing code snippets."
    ],
    embedding: [
      type: {:or, [:string, :nil]},
      default: nil,
      doc: "JSON-encoded float vector string or nil."
    ],
    limit: [
      type: :pos_integer,
      default: 10,
      doc: "Maximum search results to return."
    ]
  )

  @spec search(String.t(), keyword()) :: {[PackageDoc.t()], notices()}
  def search(query, opts \\ []) when is_binary(query) do
    case NimbleOptions.validate(opts, @search_schema) do
      {:ok, validated} ->
        case presence(validated[:package]) do
          nil -> {[], [@no_package_notice]}
          package -> search_package(query, package, validated)
        end

      {:error, %NimbleOptions.ValidationError{} = err} ->
        {[], ["Invalid search options: #{Exception.message(err)}"]}
    end
  end

  @spec search_package(String.t(), String.t(), keyword()) :: {[PackageDoc.t()], notices()}
  defp search_package(query, package, opts) do
    # Normalised once, here, so `version` has a single meaning everywhere below.
    version = presence(opts[:version]) || "latest"
    refresh = opts[:refresh]
    examples_only = opts[:include_examples_only]
    embedding = opts[:embedding]
    limit = opts[:limit]

    {notices, resolved_version} = ensure_ingested(package, version, refresh)

    base_query =
      from(d in PackageDoc)
      |> scope_package(package)
      |> scope_version(resolved_version || version)
      |> scope_examples(examples_only)

    {embedding, config_notices} = verify_embedding_model(embedding)

    {results, query_notices} = run_query(base_query, query, embedding, limit)
    {results, notices ++ config_notices ++ query_notices}
  end

  # Dropping the embedding here routes the search down the FTS-only clause of
  # `run_query/4` — the same degraded behaviour a dimension mismatch already
  # produced, except that it was reached by raising inside sqlite-vec and being
  # swallowed by a rescue, so nothing distinguished it from a search that simply
  # ranked badly. Same outcome, stated.
  #
  # Comparing model names catches the case a dimension check cannot: two models
  # of the same width are equally incomparable, and cosine distance between their
  # spaces is noise that raises nothing at all.
  @spec verify_embedding_model(term()) :: {term(), notices()}
  defp verify_embedding_model(nil), do: {nil, []}

  defp verify_embedding_model(embedding) do
    case EmbeddingConfig.check() do
      {:mismatch, stored, current} ->
        Logger.warning(
          "[Docs.Search] embedding model mismatch: index built with #{stored}, " <>
            "querying with #{current} — vector ranking disabled"
        )

        {nil, [EmbeddingConfig.mismatch_notice(stored, current)]}

      _ok_or_unset ->
        {embedding, []}
    end
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

  # Retrieve shallow from both arms, fuse, rerank the fused head.
  #
  # This replaces an *intersection*: the previous query ordered by cosine and
  # filtered with `d.id in subquery(fts_ids)`, so a document the vector arm
  # ranked first but the keyword arm never matched could not be returned at all.
  # Fusion makes it a union.
  #
  # The depths are measured, not chosen. 15 per arm and a fused head of 10 scored
  # recall@5 1.00 on the eval set; 20 per arm scored 0.96, because RRF rewards
  # agreement and deeper arms supply enough mediocre-but-agreed documents to
  # displace a strong single-arm hit. Retrieving *more* is worse here.
  @arm_depth 15
  @rerank_depth 10

  @spec run_query(Ecto.Query.t(), String.t(), list() | String.t() | nil, pos_integer()) ::
          {[PackageDoc.t()], notices()}
  defp run_query(base_query, query, vec, limit) when is_list(vec) or is_binary(vec) do
    vec_param = if is_list(vec), do: Jason.encode!(vec), else: vec
    match = QuerySanitizer.to_match(query)

    arms = [fts_ids(base_query, match), vector_ids(base_query, vec_param)]

    case Fusion.rrf(arms, max(@rerank_depth, limit)) do
      # Neither arm returned anything for this package — not an error, and not
      # something reranking can rescue.
      [] ->
        {[], []}

      ids ->
        {ids |> hydrate() |> Reranker.rerank(query) |> Enum.take(limit), []}
    end
  rescue
    e ->
      Logger.warning("[Docs.Search] fused query failed: #{Exception.message(e)}")
      run_query(base_query, query, nil, limit)
  end

  # FTS5-only: no embedding available, or the vector arm was refused because the
  # index was built by a different model.
  defp run_query(base_query, query, _vec, limit) do
    results =
      case QuerySanitizer.to_match(query) do
        "" -> Repo.all(from(d in base_query, limit: ^limit))
        match -> base_query |> fts_query(match, limit) |> Repo.all()
      end

    {results, []}
  rescue
    e ->
      Logger.warning("[Docs.Search] FTS query failed: #{Exception.message(e)}")
      {[], ["Search query failed: #{Exception.message(e)}"]}
  end

  # Both arms are scoped by joining `base_query`, which already carries the
  # package, version and examples filters. Ranking the FTS table alone and
  # filtering afterwards would spend the whole depth budget on other packages.
  defp fts_ids(_base_query, ""), do: []

  defp fts_ids(base_query, match) do
    base_query
    |> fts_query(match, @arm_depth)
    |> select([d], d.id)
    |> Repo.all()
  end

  defp fts_query(base_query, match, limit) do
    from(d in base_query,
      join: f in "package_docs_fts",
      on: d.id == f.rowid,
      where: fragment("package_docs_fts MATCH ?", ^match),
      order_by: [asc: fragment("rank")],
      limit: ^limit
    )
  end

  defp vector_ids(base_query, vec_param) do
    base_query
    |> vector_query(vec_param, @arm_depth)
    |> select([d], d.id)
    |> Repo.all()
  end

  # `id in ^ids` returns rows in storage order, so the fused ranking has to be
  # reimposed — otherwise the reranker receives its input in an arbitrary order
  # and every tie it cannot break is decided by SQLite.
  defp hydrate(ids) do
    by_id =
      from(d in PackageDoc, where: d.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(ids, fn id -> List.wrap(Map.get(by_id, id)) end)
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
  @spec decide(String.t(), String.t(), term()) :: {list(), String.t()}
  defp decide(package, requested, nil) do
    case resolve_target(package, requested) do
      {:ok, target, docs_url} -> ingest(package, target, docs_url)
      {:error, notices} -> {notices, nil}
    end
  end

  # fully-cached path and it makes no network call.
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

  # "latest" with something already stored.
  #
  # The lockfile outranks everything because it is an explicit statement about
  # *this* project, and unlike the two fallbacks it can legitimately point
  # backwards: a project on `boruta 2.3.0` must get 2.3.0 docs even though
  # 3.0.0-beta.4 is newer. Refusing to "downgrade" would serve it the wrong
  # documentation silently, which is worse than the re-ingest it costs.
  #
  # `app_version` keeps its old behaviour — report drift, never switch — because
  # it is an accident of where the server was launched rather than a statement
  # about the caller.
  defp decide(package, "latest", stored) do
    case Lockfile.version(package) do
      nil -> decide_unpinned(package, stored)
      ^stored -> serve_or_repair(package, stored, nil)
      pinned -> switch_to_locked(package, stored, pinned)
    end
  end

  defp decide_unpinned(package, stored) do
    case app_version(package) do
      ^stored -> serve_or_repair(package, stored, nil)
      _other -> compare_with_hex(package, stored)
    end
  end

  # One version per package is the invariant, so honouring a second project's
  # lockfile evicts the first project's docs. A single switch is legitimate — you
  # changed projects. Switching *repeatedly* means two projects share one
  # DATABASE_PATH and will re-download and re-embed on every alternation, which
  # no amount of searching fixes. The notice names that, because the symptom
  # otherwise reads as "the tool is slow".
  defp switch_to_locked(package, stored, pinned) do
    Logger.info("[Docs.Search] #{package}: #{stored} -> #{pinned} (pinned by #{Lockfile.path()})")

    case resolve_target(package, pinned) do
      {:ok, target, docs_url} ->
        {notices, resolved} = ingest(package, target, docs_url)

        {[locked_switch_notice(package, stored, pinned) | notices], resolved}

      {:error, notices} ->
        {notices, nil}
    end
  end

  defp locked_switch_notice(package, stored, pinned) do
    "Replaced indexed '#{package}' v#{stored} with v#{pinned}, which #{Lockfile.path()} " <>
      "pins. Only one version per package is kept. If two projects share this " <>
      "DATABASE_PATH they will evict each other and re-embed on every switch — give " <>
      "each project its own DATABASE_PATH and PROJECT_ROOT."
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
  @spec serve_or_repair(String.t(), String.t(), term()) :: {list(), String.t()}
  defp serve_or_repair(package, version, docs_url) do
    case missing_embeddings(package, version) do
      0 ->
        :ok = RepairBudget.clear(package, version)
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
      {:ok, %StdioMcp.Docs.HexPackage{} = meta} -> target_from(meta, package, requested)
      {:error, :not_found} -> {:error, ["No such package on Hex: '#{package}'."]}
      {:error, reason} -> {:error, ["Could not reach Hex for '#{package}': #{inspect(reason)}."]}
    end
  end

  # Precedence: what the caller's project locks, then what this server happens to
  # run, then what Hex calls stable. Only the first is a statement about the repo
  # being edited.
  defp target_from(meta, package, "latest") do
    case Lockfile.version(package) || app_version(package) || HexPackage.latest(meta) do
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

  # DB lookup for the `package` version
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

  # Refusing to ingest under a second embedding model is a decision, not a
  # failure, and `inspect/1` on the tuple would report it as one. The caller
  # needs the fix, which is a command, not an error term.
  defp handle_ingest_result({:ok, {:error, {:embedding_model_mismatch, stored, current}}}, _pkg) do
    {[EmbeddingConfig.mismatch_notice(stored, current)], nil}
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

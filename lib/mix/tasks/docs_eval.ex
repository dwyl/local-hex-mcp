defmodule Mix.Tasks.Docs.Eval do
  @shortdoc "Measures retrieval quality across FTS / vector / hybrid / RRF."

  @moduledoc """
  Retrieval eval harness for `search_docs`.

  Runs a fixed query set against the packages already in the local index and
  reports, per retrieval strategy, how often the right documentation chunk makes
  it into the answer. It exists so that changes to chunking, tokenisation and
  fusion can be judged by a number rather than by reading five results and
  forming an impression.

  ## Why this is a standalone instrument

  It deliberately does **not** call `StdioMcp.Docs.Search.search/2`. The point is
  to compare strategies against each other, including ones not wired into the
  server yet, and an instrument that shares code with the thing it measures stops
  being a control the moment that code changes. `rrf/2` here is also the reference
  implementation to port into SQL: doing the fusion in Elixir keeps the harness
  independent of the schema work.

  The one thing it does share is `StdioMcp.Docs.QuerySanitizer`, and that is
  deliberate: the `:fts` arm has to build byte-identical MATCH expressions to the
  ones production builds, or it is measuring a different search.

  ## Ground truth

  Each query names a package and an expectation matched against stored columns —
  never a hard-coded row id, so the query set survives a re-chunk. Expectations
  resolve to a *set* of ids (a function's docs are commonly split into "Examples
  - Foo.bar/1", "Options - Foo.bar/1" and several `- Part N` chunks); a hit is any
  member of that set.

  An expectation that resolves to **zero** rows is reported as BROKEN and excluded
  from scoring. That means the expectation is wrong, or the package is not
  indexed — not that retrieval failed — and silently scoring it as a miss would
  drag every mode down equally and hide real movement.

  ## Reading the report

    * `recall@5` — fraction of queries with a relevant chunk in the top 5. This is
      the headline: 5 is roughly what fits in an agent's answer.
    * `MRR@10` — mean reciprocal rank of the first relevant chunk. Moves when
      ordering improves even if recall does not.
    * `cand` — fraction of queries whose candidate pool contained a relevant
      chunk. It is the ceiling on `recall@5`: no ordering change can promote what
      retrieval never fetched, so if `cand` is 0.80, nothing downstream takes
      `recall@5` past 0.80. Fix recall first.
    * `ms` — median wall clock, including the embedding API call for every mode
      that needs a vector (the embedding is fetched once per query and shared, so
      the modes are comparable to each other, not to a cold production call).

  The `concept` / `symbol` split is the whole reason for the query set's shape.
  The two regimes behave differently — keyword retrieval is near-perfect on bare
  identifiers and weakest on natural-language questions — and an aggregate number
  averages them together, hiding a change that helps one and harms the other.

  ## Usage

      mix docs.eval
      mix docs.eval --only symbol
      mix docs.eval --modes fts,rrf --verbose
      mix docs.eval --candidates 60

  ## Options

    * `--modes` — comma-separated subset of `fts,vector,hybrid,rrf` (default: all)
    * `--only` — `concept` or `symbol`; default runs both
    * `--candidates` — per-arm retrieval depth (default 15). Deeper is **worse**
      here: RRF scores consensus, so with 40-deep arms an item ranked ~15 by both
      arms (1/75 + 1/75) outscores one ranked 3 by a single arm (1/63), and the
      strong single-arm hit falls out of the fused top 10. Measured: arms 10 and
      15 both give 1.00 recall@5, arms 20 gives 0.96.
    * `--limit` — cut-off for recall@k (default 5)
    * `--verbose` — per-query rank table
    * `--judged` — score against `priv/eval/judgements.md` instead of the
      expectations: `P@k` (what fraction of a returned page is useful) and
      `any-relevant`. Expectations mark at most one row and so cannot tell a
      wholly on-topic result set from one lucky substring match.
    * `--show N` — print the top N documents each query actually returns, with
      the ones counted as relevant marked. Ranks alone cannot show that an
      expectation is satisfied by a document that answers nothing, which is how
      two bad expectations survived several rounds of measurement here.
  """

  use Mix.Task

  import Ecto.Query
  import SqliteVec.Ecto.Query

  alias StdioMcp.AI.Client
  alias StdioMcp.Docs.Fusion
  alias StdioMcp.Docs.Judgements
  alias StdioMcp.Docs.QuerySanitizer
  alias StdioMcp.PackageDoc
  alias StdioMcp.Repo

  @mrr_depth 10

  # 13 conceptual + 12 symbol. Conceptual queries deliberately avoid naming the
  # identifier they should find — that is the whole test. Symbol queries are the
  # bare identifier, as an agent would paste it.
  #
  # Expectations: {:function, suffix} | {:module, exact} | {:content, substring}
  # `:function` matches on suffix because ExDoc titles arrive prefixed
  # ("Examples - Req.merge/2") and, on older packages, unqualified ("perform/3").
  @queries [
    # -- conceptual -----------------------------------------------------------
    %{
      kind: :concept,
      package: "req",
      query: "how do I automatically retry a failed request with backoff",
      expect: {:function, "Req.Steps.retry/1"}
    },
    %{
      kind: :concept,
      package: "req",
      query: "replace real HTTP calls in my tests with a stub",
      expect: {:module, "Req.Test"}
    },
    %{
      kind: :concept,
      package: "req",
      query: "follow redirects returned by the server",
      expect: {:function, "Req.Steps.redirect/1"}
    },
    %{
      kind: :concept,
      package: "exqlite",
      query: "turn on write ahead logging so readers do not block writers",
      expect: {:content, "journal_mode"}
    },
    %{
      kind: :concept,
      package: "ecto_sqlite3",
      query: "avoid database is locked errors under concurrent writes",
      expect: {:content, "busy_timeout"}
    },
    %{
      kind: :concept,
      package: "anubis_mcp",
      query: "declare a tool with a typed argument schema",
      expect: {:module, "Anubis.Server.Component.Tool"}
    },
    %{
      kind: :concept,
      package: "anubis_mcp",
      query: "return an error result from a tool back to the client",
      expect: {:function, "Anubis.Server.Response.error/2"}
    },
    %{
      kind: :concept,
      package: "anubis_mcp",
      query: "run a server that talks over standard input and output",
      expect: {:module, "Anubis.Server.Transport.STDIO"}
    },
    # Replaced 2026-08-06. The previous query here was "let a backend service
    # obtain a token with no user involved", expecting `{:content,
    # "client_credentials"}`, and it failed every arm in every run — vector search
    # never found it at all, which is what made concept `cand` 0.92 rather than
    # 1.00 and cost ~0.07 of concept recall in every table.
    #
    # It was the eval that was wrong. The expectation resolved to three rows, all
    # of them `iex>` examples where `client_credentials` appears as a string
    # literal in a params map — none of them explains the grant. boruta does not
    # document that grant in prose at all: the only conceptual home is
    # `Boruta.Oauth.ClientCredentialsRequest`, whose entire moduledoc is the four
    # words "Client credentials request". That module ranks **2 of 544** for
    # "client credentials grant" and **357 of 544** for the phrasing above, so
    # retrieval was working — the question simply had no answer in the corpus,
    # asked in vocabulary the corpus never uses.
    #
    # A query the package cannot answer measures corpus coverage, not retrieval,
    # and permanently depresses every number while hiding real movement. Replaced
    # with a question boruta genuinely documents.
    %{
      kind: :concept,
      package: "boruta",
      query: "restrict access to an HTTP endpoint using a bearer token",
      expect: {:content, "bearer"}
    },
    # Tightened 2026-08-06 after a live MCP call disagreed with the eval. The
    # expectation was `{:content, "PKCE"}`, which matched 7 rows across 6
    # modules — including `Boruta.Oauth.Client.t/0`, a typespec dump listing
    # `pkce: boolean()` among thirty other fields, and a changelog entry. The
    # server returns that typespec at rank 1, so the eval scored a perfect hit
    # while the document that actually answers the question (`pkce.html`, the
    # guide) sat at rank 8.
    #
    # An expectation that a typespec can satisfy does not measure whether the
    # answer was found. Scoped to the guide's own page, which is the only thing
    # here that explains the flow.
    %{
      kind: :concept,
      package: "boruta",
      query: "prevent interception of the authorization code on a public client",
      expect: {:module, "pkce"}
    },
    %{
      kind: :concept,
      package: "text_chunker",
      query: "keep some shared context between consecutive chunks",
      expect: {:content, "chunk_overlap"}
    },
    %{
      kind: :concept,
      package: "lazy_html",
      query: "get the visible text out of a parsed document",
      expect: {:function, "LazyHTML.text/2"}
    },
    %{
      kind: :concept,
      package: "gen_magic",
      query: "identify the type of an uploaded file from its contents",
      expect: {:content, "mime"}
    },
    # Added 2026-08-06. Unlike every other query here, these two were not written
    # by reading the corpus for something to point at — they are real questions
    # asked during a working session, whose answers were then verified by running
    # the code. That provenance matters: two of the three expectations that had to
    # be fixed in this file were reverse-engineered from the index and turned out
    # to measure corpus coverage rather than retrieval.
    %{
      kind: :concept,
      package: "anubis_mcp",
      query: "server requests a completion from the client model, sampling create message",
      expect: {:function, "Anubis.Server.send_sampling_request/2"}
    },
    # The answer shares no identifier and no phrasing with the question — the rule
    # lives in the docstring of the *elicitation* function and covers all three
    # server-initiated request kinds. Nothing the keyword arm can reach.
    %{
      kind: :concept,
      package: "anubis_mcp",
      query:
        "check whether the connected client declared a capability before sending a server request",
      expect: {:function, "Anubis.Server.send_elicitation_request/3"}
    },
    # Added after step 2. This is the query that started the investigation and it
    # was not in the set, so the set could not measure the thing step 2 fixed:
    # `Next steps` link-list chunks are made of the titles being searched for, so
    # they outranked the guide itself — five of ten FTS results and four of ten
    # vector results. Expectation is the page intro rather than the page, since
    # any section of building-a-server.html would pass too easily.
    %{
      kind: :concept,
      package: "anubis_mcp",
      query: "Building a Server",
      expect: {:content, "# Building a Server"}
    },

    # -- symbol lookups -------------------------------------------------------
    %{
      kind: :symbol,
      package: "req",
      query: "Req.merge/2",
      expect: {:function, "Req.merge/2"}
    },
    %{
      kind: :symbol,
      package: "req",
      query: "Req.new/2",
      expect: {:function, "Req.new/2"}
    },
    %{
      kind: :symbol,
      package: "req",
      query: "Req.Request.append_request_steps/2",
      expect: {:function, "Req.Request.append_request_steps/2"}
    },
    %{
      kind: :symbol,
      package: "exqlite",
      query: "Exqlite.Sqlite3.step/2",
      expect: {:function, "Exqlite.Sqlite3.step/2"}
    },
    %{
      kind: :symbol,
      package: "sqlite_vec",
      query: "vec_distance_cosine/2",
      expect: {:function, "SqliteVec.Ecto.Query.vec_distance_cosine/2"}
    },
    %{
      kind: :symbol,
      package: "sqlite_vec",
      query: "SqliteVec.Float32.new/1",
      expect: {:function, "SqliteVec.Float32.new/1"}
    },
    %{
      kind: :symbol,
      package: "lazy_html",
      query: "LazyHTML.from_document/1",
      expect: {:function, "LazyHTML.from_document/1"}
    },
    %{
      kind: :symbol,
      package: "lazy_html",
      query: "LazyHTML.query/2",
      expect: {:function, "LazyHTML.query/2"}
    },
    %{
      kind: :symbol,
      package: "text_chunker",
      query: "TextChunker.split/2",
      expect: {:function, "TextChunker.split/2"}
    },
    %{
      kind: :symbol,
      package: "anubis_mcp",
      query: "Anubis.Server.Response.json/3",
      expect: {:function, "Anubis.Server.Response.json/3"}
    },
    %{
      kind: :symbol,
      package: "gen_magic",
      query: "perform/3",
      expect: {:function, "perform/3"}
    },
    %{
      kind: :symbol,
      package: "boruta",
      query: "Boruta.Oauth.token/2",
      expect: {:function, "Boruta.Oauth.token/2"}
    }
  ]

  @doc """
  The query set, exposed so `mix docs.judge` scores the same questions rather
  than keeping a second copy that drifts.
  """
  def queries, do: @queries

  @all_modes [:fts, :vector, :hybrid, :rrf]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [
          modes: :string,
          only: :string,
          candidates: :integer,
          limit: :integer,
          verbose: :boolean,
          show: :integer,
          judged: :boolean
        ]
      )

    Mix.Task.run("app.start")

    config = %{
      modes: modes(opts),
      candidates: Keyword.get(opts, :candidates, 15),
      limit: Keyword.get(opts, :limit, 5),
      verbose?: Keyword.get(opts, :verbose, false),
      show: Keyword.get(opts, :show, 0),
      judged?: Keyword.get(opts, :judged, false)
    }

    {resolved, broken} = opts |> select_queries() |> resolve_ground_truth()
    {usable, mismatched} = reject_dimension_mismatch(resolved, config)

    report_broken(broken)
    report_mismatched(mismatched)

    case usable do
      [] ->
        Mix.shell().error("No usable queries. Nothing to measure.")

      usable ->
        usable
        |> Enum.map(&evaluate(&1, config))
        |> report(config)
    end
  end

  # -- query selection & ground truth -----------------------------------------

  defp select_queries(opts) do
    case Keyword.get(opts, :only) do
      nil -> @queries
      "concept" -> Enum.filter(@queries, &(&1.kind == :concept))
      "symbol" -> Enum.filter(@queries, &(&1.kind == :symbol))
      other -> Mix.raise("--only expects concept or symbol, got: #{other}")
    end
  end

  defp modes(opts) do
    case Keyword.get(opts, :modes) do
      nil ->
        @all_modes

      list ->
        list
        |> String.split(",", trim: true)
        |> Enum.map(fn name ->
          mode = String.to_existing_atom(String.trim(name))
          if mode in @all_modes, do: mode, else: Mix.raise("unknown mode: #{name}")
        end)
    end
  end

  # A query whose expectation matches nothing is a broken *expectation*, not a
  # retrieval miss, and scoring it as a miss would move every mode by the same
  # amount while looking like a real result.
  defp resolve_ground_truth(queries) do
    queries
    |> Enum.map(fn q -> Map.put(q, :relevant, relevant_ids(q)) end)
    |> Enum.split_with(&(MapSet.size(&1.relevant) > 0))
  end

  defp relevant_ids(%{package: package, expect: expect}) do
    from(d in PackageDoc, where: d.package == ^package, select: d.id)
    |> match_expectation(expect)
    |> Repo.all()
    |> MapSet.new()
  end

  # Suffix match: ExDoc titles arrive as "Examples - Req.merge/2" on modern
  # packages and bare "perform/3" on older ones, so anchoring at the end is the
  # only form that covers both without also matching
  # "Boruta.Oauth.TokenApplication.token_error/2".
  defp match_expectation(query, {:function, name}) do
    from(d in query, where: fragment("? LIKE ? ESCAPE '\\'", d.function, ^("%" <> escape(name))))
  end

  defp match_expectation(query, {:module, name}), do: from(d in query, where: d.module == ^name)

  defp match_expectation(query, {:content, text}) do
    from(d in query,
      where: fragment("? LIKE ? ESCAPE '\\'", d.content, ^("%" <> escape(text) <> "%"))
    )
  end

  # `_` is a LIKE wildcard and half these patterns contain one (`busy_timeout`,
  # `chunk_overlap`, `client_credentials`). Unescaped they still match
  # themselves, so nothing looks wrong — they just also match anything else with
  # a character in that position, quietly inflating the relevant set.
  defp escape(pattern) do
    pattern
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # Stored vectors carry no record of which model produced them, so a package
  # embedded by one model and queried by another is only discovered when
  # sqlite-vec refuses the pair. In production that refusal is rescued and the
  # search silently degrades to FTS-only (see StdioMcp.Docs.Search.run_query/4),
  # which looks like a bad ranking rather than a dead arm. Here it must be a
  # named finding, not a crash: the eval's job is to report it.
  defp reject_dimension_mismatch(queries, config) do
    if needs_vector?(config.modes) do
      dims = probe_dims()
      Enum.split_with(queries, fn q -> stored_dims(q.package) in [nil, dims] end)
    else
      {queries, []}
    end
  end

  defp probe_dims do
    "dimension probe" |> embed!() |> Jason.decode!() |> length()
  end

  # Counting commas beats decoding a 1536-element JSON array just to length it.
  defp stored_dims(package) do
    Repo.one(
      from(d in PackageDoc,
        where: d.package == ^package and not is_nil(d.embedding) and d.embedding != "",
        limit: 1,
        select: fragment("length(?) - length(replace(?, ',', '')) + 1", d.embedding, d.embedding)
      )
    )
  end

  defp report_mismatched([]), do: :ok

  defp report_mismatched(queries) do
    by_package = Enum.group_by(queries, & &1.package)
    expected = probe_dims()

    Mix.shell().error(
      "\n#{length(queries)} query(ies) excluded — stored embeddings were built by a " <>
        "different model than #{Client.embed_model()} (#{expected} dims):\n"
    )

    Enum.each(by_package, fn {package, qs} ->
      Mix.shell().error(
        "  #{package}: stored #{stored_dims(package)} dims, #{length(qs)} query(ies)"
      )
    end)

    Mix.shell().error("""

    Vector search cannot run against these. In the MCP server the same mismatch
    raises inside run_query/4, is rescued, and the search silently answers from
    FTS alone — so results look merely bad rather than broken.

    Fix by re-ingesting each listed package under the model you query with:
      AI_EMBED_MODEL=#{Client.embed_model()} iex -S mix
      StdioMcp.Docs.Search.search("x", package: "<name>", refresh: true)
    """)
  end

  defp report_broken([]), do: :ok

  defp report_broken(broken) do
    Mix.shell().error("\n#{length(broken)} expectation(s) matched no rows — excluded:\n")

    Enum.each(broken, fn q ->
      Mix.shell().error("  [#{q.package}] #{inspect(q.expect)}  (#{q.query})")
    end)

    Mix.shell().error(
      "\nEither the package is not indexed (mix docs.eval only measures what is " <>
        "already in the DB), or the expectation names something ExDoc titles " <>
        "differently. Check with:\n" <>
        "  select distinct function from package_docs where package = '...';\n"
    )
  end

  # -- per-query evaluation ----------------------------------------------------

  # The query embedding is fetched once and shared across modes: 25 queries x 4
  # modes would otherwise be 100 API calls to measure 25 questions, and the modes
  # would no longer be comparing retrieval — they would be comparing which one
  # got a slow HTTP round trip.
  defp evaluate(q, config) do
    vec = if needs_vector?(config.modes), do: embed!(q.query)

    runs =
      Map.new(config.modes, fn mode ->
        {us, ids} = :timer.tc(fn -> candidates(mode, q, vec, config.candidates) end)
        {mode, %{ids: ids, us: us}}
      end)

    %{query: q, runs: runs}
  end

  # `--modes fts` must not spend 25 embedding calls to measure an arm that has no
  # vector in it — that is also the only configuration that runs without an API
  # key, which makes it the one to reach for when checking the harness itself.
  defp needs_vector?(modes), do: Enum.any?(modes, &(&1 in [:vector, :hybrid, :rrf]))

  # One input per request, one request per query, and no pacing is exactly the
  # shape a requests-per-second limiter punishes — the ingest path avoids it by
  # batching 200 inputs into one call, which this cannot do because each query
  # needs its own vector. So it retries on 429, honouring the server's
  # Retry-After when it sends one, mirroring TarballIngestion.embed_batch/2.
  @embed_attempts 5
  @embed_backoff_ms 1_000
  @embed_backoff_max_ms 30_000

  defp embed!(query, attempt \\ 1) do
    case Client.embed(query) do
      {:ok, embedding} ->
        Jason.encode!(embedding)

      {:error, {429, retry_after_ms}} when attempt < @embed_attempts ->
        delay = backoff(retry_after_ms, attempt)
        Mix.shell().info("  rate limited, retrying in #{delay}ms …")
        Process.sleep(delay)
        embed!(query, attempt + 1)

      {:error, reason} ->
        Mix.raise("embedding failed for #{inspect(query)}: #{inspect(reason)}")
    end
  end

  defp backoff(retry_after_ms, _attempt) when is_integer(retry_after_ms),
    do: min(retry_after_ms, @embed_backoff_max_ms)

  defp backoff(_retry_after_ms, attempt),
    do: min(@embed_backoff_ms * Integer.pow(2, attempt - 1), @embed_backoff_max_ms)

  # -- retrieval arms ----------------------------------------------------------

  defp candidates(:fts, q, _vec, n), do: fts_ids(q.package, q.query, n)
  defp candidates(:vector, q, vec, n), do: vector_ids(q.package, vec, n)

  # Production behaviour as of StdioMcp.Docs.Search.hybrid_query/4: vector
  # ordering *intersected* with the FTS candidate set, falling back to
  # vector-only when the intersection is empty. Kept as the baseline the new
  # pipeline has to beat — an intersection cannot surface a chunk the keyword arm
  # never matched, which is precisely what RRF is meant to fix.
  defp candidates(:hybrid, q, vec, n) do
    fts = MapSet.new(fts_ids(q.package, q.query, n))

    case Enum.filter(vector_ids(q.package, vec, n), &MapSet.member?(fts, &1)) do
      [] -> vector_ids(q.package, vec, n)
      hits -> hits
    end
  end

  defp candidates(:rrf, q, vec, n) do
    rrf([fts_ids(q.package, q.query, n), vector_ids(q.package, vec, n)], n)
  end

  defp fts_ids(package, query, n) do
    case sanitize_fts(query) do
      "" ->
        []

      match ->
        from(f in "package_docs_fts",
          where: fragment("package_docs_fts MATCH ?", ^match),
          where: fragment("package = ?", ^package),
          order_by: [asc: fragment("rank")],
          limit: ^n,
          select: f.rowid
        )
        |> Repo.all()
    end
  rescue
    e ->
      Mix.shell().error("  fts failed for #{inspect(query)}: #{Exception.message(e)}")
      []
  end

  defp vector_ids(package, vec, n) do
    from(d in PackageDoc,
      where: d.package == ^package and not is_nil(d.embedding) and d.embedding != "",
      order_by: [asc: vec_distance_cosine(d.embedding, ^vec)],
      limit: ^n,
      select: d.id
    )
    |> Repo.all()
  end

  # Fusion comes from the module `Docs.Search` uses. The arms stay local, because
  # the harness has to compare strategies the server does not implement —
  # `hybrid` is the intersection RRF replaced, kept as the control — but
  # reimplementing the stage that *is* production would let the `rrf` row drift
  # away from describing the server.
  defp rrf(ranked_lists, n), do: Fusion.rrf(ranked_lists, n)

  defp sanitize_fts(query), do: QuerySanitizer.to_match(query)

  # `id in ^ids` returns rows in whatever order SQLite likes, so the fused
  # ordering has to be reimposed — otherwise any tie is decided by the storage
  # engine rather than by the ranking under test.
  defp hydrate(ids) do
    by_id =
      from(d in PackageDoc, where: d.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(ids, fn id -> List.wrap(Map.get(by_id, id)) end)
  end

  # -- reporting ---------------------------------------------------------------

  defp report(evaluations, config) do
    modes = config.modes

    Mix.shell().info("""

    #{length(evaluations)} queries · top-#{config.limit} · #{config.candidates} per arm
    corpus #{corpus_fingerprint()}
    """)

    section("all", evaluations, modes, config)

    by_kind = Enum.group_by(evaluations, & &1.query.kind)

    for kind <- [:concept, :symbol], evals = by_kind[kind], evals != [] do
      section("#{kind} (#{length(evals)})", evals, modes, config)
    end

    if config.judged?, do: judged_report(evaluations, List.last(modes), config)
    if config.verbose?, do: detail(evaluations, modes, config)
    if config.show > 0, do: show_results(evaluations, List.last(modes), config)
  end

  # Ranks are a proxy and a proxy cannot be audited by eye. `[boruta] PKCE`
  # scored a rank-1 hit while the document returned was a typespec listing
  # `pkce: boolean()` among thirty fields — technically in the relevant set,
  # useless as an answer. This prints what a caller would actually receive, with
  # the ones counted as relevant marked, so the expectation itself can be judged
  # rather than trusted.
  defp show_results(evaluations, mode, config) do
    Mix.shell().info("\n" <> String.duplicate("=", 78))
    Mix.shell().info("WHAT THE CALLER ACTUALLY GETS  ·  #{mode}  ·  top #{config.show}\n")

    Enum.each(evaluations, fn %{query: q} = e ->
      Mix.shell().info("#{q.kind |> to_string() |> String.upcase()}  [#{q.package}]  #{q.query}")
      Mix.shell().info("  expect #{inspect(q.expect)}")

      e.runs
      |> Map.fetch!(mode)
      |> Map.fetch!(:ids)
      |> Enum.take(config.show)
      |> hydrate()
      |> Enum.with_index(1)
      |> Enum.each(fn {doc, i} ->
        mark = if MapSet.member?(q.relevant, doc.id), do: "✓", else: " "

        excerpt =
          doc.content |> to_string() |> String.replace(~r/\s+/, " ") |> String.slice(0, 96)

        Mix.shell().info("  #{mark} #{i}. #{String.slice(to_string(doc.signature), 0, 58)}")
        Mix.shell().info("      #{excerpt}")
      end)

      Mix.shell().info("")
    end)
  end

  # BM25 is collection-global: FTS5's `bm25()` uses corpus-wide document
  # frequency and average document length, so ingesting *any* package changes the
  # keyword ranking of queries in *other* packages. Measured — indexing 53 rows
  # of `nimble_options` moved the `fts` arm from 0.92 to 0.88 with nothing else
  # touched, and every fused row followed it.
  #
  # A control table is therefore only valid for the corpus that produced it. This
  # line makes a mismatched comparison visible instead of silently wrong.
  defp corpus_fingerprint do
    %{packages: packages, rows: rows} =
      Repo.one(
        from(d in PackageDoc,
          select: %{packages: count(d.package, :distinct), rows: count(d.id)}
        )
      )

    "#{packages} packages / #{rows} rows"
  end

  defp section(label, evaluations, modes, config) do
    Mix.shell().info(
      String.pad_trailing(label, 14) <>
        "recall@#{config.limit}   MRR@#{@mrr_depth}      cand        ms"
    )

    Enum.each(modes, fn mode ->
      stats = summarize(evaluations, mode, config)

      Mix.shell().info(
        String.pad_trailing(to_string(mode), 14) <>
          pad(stats.recall) <>
          pad(stats.mrr) <>
          pad(stats.candidate_recall) <>
          String.pad_leading(Integer.to_string(stats.median_ms), 10)
      )
    end)

    Mix.shell().info("")
  end

  defp summarize(evaluations, mode, config) do
    runs = Enum.map(evaluations, fn e -> {e.query.relevant, Map.fetch!(e.runs, mode)} end)

    %{
      recall: mean(runs, fn {rel, run} -> bool(hit?(run.ids, rel, config.limit)) end),
      mrr: mean(runs, fn {rel, run} -> reciprocal_rank(run.ids, rel) end),
      candidate_recall: mean(runs, fn {rel, run} -> bool(hit?(run.ids, rel, :all)) end),
      median_ms: runs |> Enum.map(fn {_rel, run} -> div(run.us, 1000) end) |> median()
    }
  end

  defp detail(evaluations, modes, config) do
    Mix.shell().info("rank of first relevant chunk (· = not in top #{config.candidates})\n")

    Mix.shell().info(
      String.pad_trailing("query", 52) <>
        Enum.map_join(modes, "", &String.pad_leading(to_string(&1), 12))
    )

    Enum.each(evaluations, fn e ->
      cells =
        Enum.map_join(modes, "", fn mode ->
          run = Map.fetch!(e.runs, mode)

          case first_rank(run.ids, e.query.relevant) do
            nil -> String.pad_leading("·", 12)
            rank -> String.pad_leading(Integer.to_string(rank), 12)
          end
        end)

      label = "[#{e.query.package}] #{e.query.query}"
      Mix.shell().info(String.pad_trailing(String.slice(label, 0, 50), 52) <> cells)
    end)

    Mix.shell().info("")
    _ = config
  end

  # Scores against human judgements instead of the single-target expectations.
  #
  # `P@5` is the number the expectations could never report: what fraction of a
  # returned page is actually useful. An expectation marks at most one row, so it
  # cannot distinguish a result set where every row is on topic from one where a
  # single lucky row matched a substring — which is precisely the complaint that
  # produced this mode.
  #
  # Unjudged rows are excluded from both numerator and denominator rather than
  # counted against the system, so a partly-marked file reports honestly on what
  # it knows. `coverage` says how much that is.
  defp judged_report(evaluations, mode, config) do
    judgements = Judgements.load()

    if map_size(judgements) == 0 do
      Mix.shell().error(
        "Nothing marked in #{Judgements.path()} yet. Generate it with `mix docs.judge`, " <>
          "then change `?` to `y` or `n` on the results you have an opinion about — " <>
          "partial marking is fine, coverage is reported.\n"
      )
    else
      scored =
        Enum.map(evaluations, fn e ->
          docs =
            e.runs |> Map.fetch!(mode) |> Map.fetch!(:ids) |> Enum.take(config.limit) |> hydrate()

          verdicts =
            Enum.map(
              docs,
              &Judgements.verdict(judgements, e.query.query, &1.package, &1.hexdocs_url)
            )

          %{kind: e.query.kind, verdicts: verdicts}
        end)

      Mix.shell().info("\njudged relevance · #{mode} · top #{config.limit}\n")
      judged_section("all", scored)

      for kind <- [:concept, :symbol] do
        case Enum.filter(scored, &(&1.kind == kind)) do
          [] -> :ok
          subset -> judged_section("#{kind} (#{length(subset)})", subset)
        end
      end
    end
  end

  defp judged_section(label, scored) do
    all = Enum.flat_map(scored, & &1.verdicts)
    known = Enum.reject(all, &(&1 == :unjudged))

    precision =
      scored
      |> Enum.map(fn %{verdicts: v} ->
        case Enum.reject(v, &(&1 == :unjudged)) do
          [] -> nil
          judged -> Enum.count(judged, &(&1 == :yes)) / length(judged)
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> mean_of()

    # Restricted to queries with at least one judgement, exactly like P@k. Averaged
    # over every query it silently reports "0.04" for a partly-marked file, which
    # reads as catastrophic failure rather than as absent data.
    success =
      scored
      |> Enum.filter(fn %{verdicts: v} -> Enum.any?(v, &(&1 != :unjudged)) end)
      |> Enum.map(fn %{verdicts: v} -> bool(:yes in v) end)
      |> mean_of()

    coverage = if all == [], do: 0.0, else: length(known) / length(all)

    Mix.shell().info(
      String.pad_trailing(label, 16) <>
        "P@k " <>
        pad(precision) <> "   any-relevant " <> pad(success) <> "   coverage " <> pad(coverage)
    )
  end

  defp mean_of([]), do: 0.0
  defp mean_of(list), do: Enum.sum(list) / length(list)

  # -- metrics -----------------------------------------------------------------

  defp first_rank(ids, relevant) do
    case Enum.find_index(ids, &MapSet.member?(relevant, &1)) do
      nil -> nil
      idx -> idx + 1
    end
  end

  defp hit?(ids, relevant, :all), do: first_rank(ids, relevant) != nil

  defp hit?(ids, relevant, limit) do
    case first_rank(ids, relevant) do
      nil -> false
      rank -> rank <= limit
    end
  end

  defp reciprocal_rank(ids, relevant) do
    case first_rank(ids, relevant) do
      nil -> 0.0
      rank when rank <= @mrr_depth -> 1 / rank
      _beyond_depth -> 0.0
    end
  end

  defp bool(true), do: 1.0
  defp bool(false), do: 0.0

  defp mean([], _fun), do: 0.0
  defp mean(list, fun), do: Enum.sum(Enum.map(list, fun)) / length(list)

  defp median([]), do: 0
  defp median(list), do: list |> Enum.sort() |> Enum.at(div(length(list), 2))

  defp pad(value), do: String.pad_leading(:erlang.float_to_binary(value * 1.0, decimals: 2), 10)
end

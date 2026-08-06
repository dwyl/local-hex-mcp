defmodule StdioMcp.Tools.SearchDocs do
  @moduledoc """
  Search official HexDocs documentation, typespecs, guides and code examples for
  a single Hex package, with keyword and semantic (vector) ranking.

  Prefer this over grepping `deps/` when:

    * the package is **not installed** — evaluating a library before adding it to
      mix.exs, where there is nothing on disk to grep;
    * you do not know the keyword — semantic ranking finds "how do I avoid
      re-embedding" when the docs actually say `chunk_overlap`;
    * you need a **citable URL** — results carry the exact `hexdocs_url`;
    * you need a version you do not have installed.

  Prefer `grep` on `deps/` when the package *is* installed and you want a
  function signature, an implementation detail, or surrounding context: the
  source is faster to reach and is the authority, and hex packages ship their
  README there too.

  Results are always scoped to **one package**, so a question spanning several is
  several calls: issue one per package and consolidate the answers yourself
  rather than asking the user to. Write a distinct query for each, using the
  terms that package's own docs would use — sending the same sentence to both
  matches neither well. Keep the package name out of `query`; it is already
  scoped by `package`, and repeating it only adds noise to the keyword search and
  dilutes the query embedding.

  When the calling project depends on the package, read its locked version from
  `mix.lock` and pass it as `version`. Omitting it does not fall back to that
  project — this server cannot see its lockfile, and resolves `"latest"` from its
  own dependencies or Hex's latest stable release, which may be a different major
  line. Omit `version` only when nothing local pins the package, such as when
  evaluating a library you have not adopted.

  Read the `notices` field: it reports version drift, ingestion still running,
  and missing embeddings, and each notice names the argument to change.
  """

  # Left at the `:forbidden` default deliberately. Declaring
  # `task_support: :optional` was probed on 2026-08-03 against anubis_mcp v1.14.0:
  # the tool advertised `execution.taskSupport` in tools/list and the client still
  # never populated `frame.task_id`, so Claude Code does not implement the MCP
  # 2025-11-25 task augmentation. Advertising a capability no client exercises
  # only invites augmented calls this tool has no code path for.
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias StdioMcp.AI.Client
  alias StdioMcp.Docs.Search

  schema do
    field(:query, :string,
      required: true,
      description:
        "Search query for Elixir package documentation, modules, typespecs, and code examples."
    )

    field(:package, :string,
      required: true,
      description:
        "Hex package name to search within (e.g. 'boruta', 'anubis_mcp', 'phoenix', 'ecto', 'req'). Searches are always scoped to one package — a cross-package search answers with rows from unrelated packages that merely share keywords, which is indistinguishable from a real answer. Also triggers ingestion from Hex.pm when the package is not indexed yet, so name the package even when unsure whether it is present."
    )

    field(:version, :string,
      description:
        "Optional package version, or 'latest' to target the newest release. Does not by itself re-download docs already indexed — use `refresh` for that."
    )

    field(:refresh, :boolean,
      description:
        "Optional boolean to force re-ingesting the package's docs from Hex.pm, replacing what is indexed. Use when docs are stale or the local index looks wrong."
    )

    field(:include_examples_only, :boolean,
      description: "Optional boolean to filter results to only entries containing code snippets."
    )
  end

  @impl true
  def execute(params, frame) do
    query = params[:query]
    package = params[:package]
    version = params[:version]
    examples_only = params[:include_examples_only] || false

    # Re-ingesting used to be bound to `version == "latest"`, which is also the
    # most casual way to say "I don't care which version" — so ordinary queries
    # paid a full re-download, and asking to refresh one specific version was
    # impossible. It is its own flag now.
    refresh = params[:refresh] || false

    vector =
      case Client.embed(query) do
        {:ok, emb} -> Jason.encode!(emb)
        _ -> nil
      end

    opts = [
      package: package,
      version: version,
      refresh: refresh,
      include_examples_only: examples_only,
      embedding: vector,
      # 5, not 10. The pipeline reranks a pool of 10 and `recall@5` is what the
      # eval optimises, so returning all 10 hands back the tail the cross-encoder
      # has just finished demoting — measured live, the last two or three rows of
      # every search were changelog entries and unrelated functions. Returning
      # the reranked head costs nothing measurable and drops roughly a third of
      # the payload.
      limit: 5
    ]

    {results, notices} = Search.search(query, opts)

    formatted =
      Enum.map(results, fn r ->
        %{
          id: r.id,
          package: r.package,
          version: r.version,
          doc_type: r.doc_type,
          module: r.module,
          function: r.function,
          signature: r.signature,
          content: r.content,
          hexdocs_url: r.hexdocs_url
        }
      end)

    payload =
      if notices == [], do: %{results: formatted}, else: %{results: formatted, notices: notices}

    {:reply, Response.text(Response.tool(), Jason.encode!(payload)), frame}
  rescue
    e ->
      {:reply, Response.text(Response.tool(), "Search docs failed: #{Exception.message(e)}"),
       frame}
  end
end

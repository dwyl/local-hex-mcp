defmodule StdioMcp.Tools.SearchDocs do
  @moduledoc "Search Hex package documentation, typespecs, and code examples."

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
      description:
        "Optional Hex package name filter (e.g. 'boruta', 'anubis_mcp', 'phoenix', 'ecto', 'req'). Supplying a package auto-ingests its docs from Hex.pm if not yet indexed."
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
      limit: 10
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

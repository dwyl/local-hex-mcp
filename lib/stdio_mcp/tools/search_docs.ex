defmodule StdioMcp.Tools.SearchDocs do
  @moduledoc "Search Hex package documentation, typespecs, and code examples."

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias StdioMcp.AI.Client
  alias StdioMcp.Docs.Search

  schema do
    field(:query, :string, required: true, description: "Search query for Elixir package documentation, modules, typespecs, and code examples.")
    field(:package, :string, description: "Optional Hex package name filter (e.g. 'boruta', 'anubis_mcp', 'phoenix', 'ecto', 'req'). Supplying a package auto-ingests its docs from Hex.pm if not yet indexed.")
    field(:version, :string, description: "Optional package version or 'latest' to force refreshing docs from Hex.pm.")
    field(:include_examples_only, :boolean, description: "Optional boolean to filter results to only entries containing code snippets.")
  end

  @impl true
  def execute(params, frame) do
    query = params[:query]
    package = params[:package]
    version = params[:version]
    examples_only = params[:include_examples_only] || false

    vector =
      case Client.embed(query) do
        {:ok, emb} -> Jason.encode!(emb)
        _ -> nil
      end

    opts = [
      package: package,
      version: version,
      refresh: version == "latest",
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

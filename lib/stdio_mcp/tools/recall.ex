defmodule StdioMcp.Tools.Recall do
  @moduledoc "Search the knowledge base for relevant technical learnings."

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias StdioMcp.Memory

  schema do
    field(:query, :string, required: true, description: "Search query for past architectural decisions, solved issues, or lessons learned.")
    field(:kind, :string, description: "Filter by memory kind: 'pain_point', 'architecture', 'best_practice', or 'quirk'.")
    field(:domain, :string, description: "Filter by domain: 'phoenix', 'ecto', 'liveview', 'mcp', 'oauth', 'beam'.")
    field(:package, :string, description: "Filter by library or package name (e.g. 'anubis_mcp', 'boruta', 'req').")
  end

  @impl true
  def execute(params, frame) do
    query = params[:query]
    opts = [limit: 5, kind: params[:kind], domain: params[:domain], package: params[:package]]

    results = Memory.search(query, opts)

    formatted =
      Enum.map(results, fn r ->
        %{
          id: r.id,
          title: r.title,
          kind: r.kind,
          content: r.content,
          metadata: r.metadata
        }
      end)

    {:reply, Response.text(Response.tool(), Jason.encode!(formatted)), frame}
  rescue
    e ->
      {:reply, Response.text(Response.tool(), "Recall failed: #{Exception.message(e)}"), frame}
  end
end

defmodule StdioMcp.MCPServer do
  @moduledoc """
  Anubis MCP Server exposing tools over stdio with SQLite FTS5 + vector search.
  """
  use Anubis.Server,
    name: "stdio-mcp",
    version: "1.0.0",
    capabilities: [:tools]

  component(StdioMcp.Tools.SearchHexPackages)
  component(StdioMcp.Tools.SearchGithubIssues)
  component(StdioMcp.Tools.SearchDocs)
  component(StdioMcp.Tools.Remember)
  component(StdioMcp.Tools.Recall)
  component(StdioMcp.Tools.GetTokenUsage)
end

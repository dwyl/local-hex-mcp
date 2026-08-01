defmodule StdioMcp.Tools.SearchGithubIssues do
  @moduledoc "Search GitHub issues and pull requests within an organization."

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field(:org, :string, required: true, description: "GitHub organization or user account name (e.g. 'phoenixframework', 'elixir-ecto').")
    field(:query, :string, required: true, description: "Search query for issue titles or content.")
  end

  @impl true
  def execute(%{org: org, query: query}, frame) do
    token = Application.get_env(:stdio_mcp, :github_token)
    headers = [{"user-agent", "stdio_mcp/1.0"}]

    headers =
      if token && token != "", do: [{"authorization", "Bearer #{token}"} | headers], else: headers

    q = "#{query} org:#{org} is:issue"
    url = "https://api.github.com/search/issues?q=#{URI.encode(q)}&per_page=10"

    case Req.get(url, headers: headers, finch: StdioMcp.Finch) do
      {:ok, %{status: 200, body: %{"items" => items}}} ->
        results =
          Enum.map(items, fn i ->
            %{
              title: i["title"],
              url: i["html_url"],
              state: i["state"],
              user: get_in(i, ["user", "login"]),
              body: String.slice(i["body"] || "", 0, 300)
            }
          end)

        {:reply, Response.text(Response.tool(), Jason.encode!(results)), frame}

      {:error, reason} ->
        {:reply, Response.text(Response.tool(), "GitHub search failed: #{inspect(reason)}"),
         frame}
    end
  end
end

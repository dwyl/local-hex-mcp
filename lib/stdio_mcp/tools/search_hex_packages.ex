defmodule StdioMcp.Tools.SearchHexPackages do
  @moduledoc """
  Search Hex.pm for packages by keyword, sorted by downloads.

  This finds *which* package to use — name, description, download counts, links.
  It does not read documentation: once you know the package name, use
  `search_docs` with `package:` set, which fetches and indexes its docs.

  Reach for it when evaluating options ("what do people use for HTTP in
  Elixir?"), or to confirm a package's exact name before searching its docs.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field(:query, :string,
      required: true,
      description: "Search query for Hex.pm package names or descriptions."
    )
  end

  @impl true
  def execute(%{query: query}, frame) do
    url = "https://hex.pm/api/packages?search=#{URI.encode(query)}&sort=downloads"

    case Req.get(url, headers: [{"user-agent", "stdio_mcp/1.0"}], finch: [name: StdioMcp.Finch]) do
      {:ok, %{status: 200, body: packages}} when is_list(packages) ->
        results =
          packages
          |> Enum.take(10)
          |> Enum.map(fn p ->
            meta = Map.get(p, "meta", %{})

            %{
              name: p["name"],
              version: p["latest_version"],
              description: meta["description"],
              downloads: get_in(p, ["downloads", "all"]),
              html_url: p["html_url"],
              docs_url: p["docs_html_url"]
            }
          end)

        {:reply, Response.text(Response.tool(), Jason.encode!(results)), frame}

      {:error, reason} ->
        {:reply, Response.text(Response.tool(), "Hex search failed: #{inspect(reason)}"), frame}
    end
  rescue
    e ->
      require Logger

      Logger.error(
        "[SearchHexPackages] Tool execution failed:\n#{Exception.format(:error, e, __STACKTRACE__)}"
      )

      {:reply,
       Response.text(Response.tool(), "Search Hex packages failed: #{Exception.message(e)}"),
       frame}
  end
end

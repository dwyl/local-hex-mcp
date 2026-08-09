defmodule StdioMcp.Tools.SearchGithubIssues do
  @moduledoc """
  Search GitHub issues **and pull requests**, open and closed, in a repository or
  across an organization.

  This is a **live query against the GitHub API** — nothing is stored locally and
  results reflect the repository as it is now. That makes it the right tool for
  "is this a known bug", "was this fixed upstream", or "has anyone hit this
  error", where documentation cannot help because the behaviour is unreleased,
  undocumented or contested.

  Pass `repo` (`owner/name`) when you know the library's repository; it is
  strictly narrower than `org` and returns less noise. Pass `org` when the
  repository is unknown or the question spans several. At least one is required;
  passing both is legal but pointless, since GitHub ANDs them and `repo` already
  implies its owner.

  **Closed results are usually the valuable ones**, which is why nothing filters
  by state: a closed issue plus its merged PR tells you what the maintainer has
  already accepted as a bug. That is the difference between opening a feature
  request and pointing at a fix that missed one code path.

  Rate limits apply unauthenticated; set `GITHUB_TOKEN` to raise them.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias StdioMcp.Docs.HexPackage

  schema do
    field(:query, :string,
      required: true,
      description: "Search terms matched against issue and PR titles and bodies."
    )

    field(:package, :string,
      description:
        "Hex package name (e.g. 'anubis_mcp'). The normal path: its repository is resolved from Hex metadata, so you do not have to know that a package lives at 'zoedsoupe/anubis-mcp'. Same identifier as `search_docs` and `list_indexed_packages`."
    )

    field(:repo, :string,
      description:
        "Repository as 'owner/name' (e.g. 'zoedsoupe/anubis-mcp'). Use when the repo is known, or for something that is not a Hex package."
    )

    field(:org, :string,
      description:
        "Organization or user account (e.g. 'phoenixframework', 'zoedsoupe'). Use when the repository is unknown or the question spans several."
    )

    field(:type, :string,
      description:
        "'issue' or 'pr'. Omit to search both, which is the useful default — a merged PR is often the answer to 'was this fixed upstream'."
    )

    field(:limit, :integer, description: "Results to return, 1-50. Defaults to 10.")
  end

  @impl true
  def execute(params, frame) do
    query = Map.get(params, :query)

    case scope(Map.get(params, :package), Map.get(params, :repo), Map.get(params, :org)) do
      {:ok, scope} ->
        opts = %{
          type_filter: type_filter(Map.get(params, :type)),
          limit: clamp(Map.get(params, :limit), 1, 50, 10)
        }

        run(query, scope, opts, frame)

      {:error, message} ->
        {:reply, Response.text(Response.tool(), message), frame}
    end
  rescue
    e ->
      require Logger

      Logger.error(
        "[SearchGithubIssues] Tool execution failed:\n#{Exception.format(:error, e, __STACKTRACE__)}"
      )

      {:reply,
       Response.text(Response.tool(), "Search GitHub issues failed: #{Exception.message(e)}"),
       frame}
  end

  # Precedence: an explicit `repo` beats a resolved `package`, which beats `org`.
  #
  # `package` is the normal path and the reason this resolver exists: a caller
  # knows `anubis_mcp`, not that its code lives at `zoedsoupe/anubis-mcp`, and
  # `org:` is precisely the argument that cannot be guessed. It also makes one
  # identifier work across `search_docs`, `list_indexed_packages` and this tool,
  # which is what lets them be chained without a lookup step in between.
  #
  # Resolution costs no extra request in the sense that matters: `HexPackage`
  # already parses `github_url` out of the same `/packages/:name` response that
  # version resolution needs.
  #
  # `repo` and `org` are never combined. GitHub ANDs the two qualifiers, so the
  # pair can only ever resolve to the repository, and naming an org that does not
  # own it returns nothing at all rather than an error.
  defp scope(package, repo, org) do
    case {presence(package), presence(repo), presence(org)} do
      {nil, nil, nil} ->
        {:error,
         "Pass package (a Hex name), repo (\"owner/name\") or org — one is required to scope the search."}

      {_package, repo, _org} when is_binary(repo) ->
        validate_repo(repo)

      {package, nil, org} when is_binary(package) ->
        resolve_package(package, org)

      {nil, nil, org} ->
        {:ok, "org:#{org}"}
    end
  end

  # Falling back to `org` when the package has no GitHub link is deliberate: a
  # package hosted elsewhere should still be searchable if the caller happened to
  # give both, rather than failing on the more specific argument.
  defp resolve_package(package, org) do
    case HexPackage.fetch(package) do
      {:ok, %HexPackage{github_url: "https://github.com/" <> path}} when path != "" ->
        # Only the first two segments are the repository. Even the GitHub-named
        # link is sometimes a deep link (`…/nats.ex/blob/master/CHANGELOG.md`),
        # and anything past `owner/name` makes the qualifier match nothing.
        case String.split(path, "/", trim: true) do
          [owner, name | _] -> {:ok, "repo:#{owner}/#{String.trim_trailing(name, ".git")}"}
          _ -> fallback(package, org, "has a GitHub link that is not a repository")
        end

      {:ok, %HexPackage{}} ->
        fallback(package, org, "has no GitHub link in its Hex metadata")

      {:error, :not_found} ->
        fallback(package, org, "is not a package on Hex")

      {:error, reason} ->
        fallback(package, org, "could not be resolved (#{inspect(reason)})")
    end
  end

  defp fallback(_package, org, _why) when is_binary(org), do: {:ok, "org:#{org}"}

  defp fallback(package, _org, why),
    do: {:error, "'#{package}' #{why}. Pass repo (\"owner/name\") or org instead."}

  defp validate_repo(repo) do
    if String.contains?(repo, "/"),
      do: {:ok, "repo:#{repo}"},
      else:
        {:error, "repo must be \"owner/name\" (got #{inspect(repo)}); use org for an account."}
  end

  # No filter is the default on purpose. `/search/issues` returns issues and pull
  # requests together, and an unconditional `is:issue` hid exactly the results
  # worth having — a merged PR fixing the bug you are looking at.
  defp type_filter("issue"), do: "is:issue"
  defp type_filter("pr"), do: "is:pr"
  defp type_filter(_), do: nil

  defp run(query, scope, %{type_filter: type_filter, limit: limit}, frame) do
    q = [query, scope, type_filter] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
    url = "https://api.github.com/search/issues?q=#{URI.encode(q)}&per_page=#{limit}"

    case Req.get(url, headers: headers(), finch: [name: StdioMcp.Finch]) do
      {:ok, %{status: 200, body: %{"items" => items}}} ->
        {:reply, Response.text(Response.tool(), Jason.encode!(Enum.map(items, &item/1))), frame}

      {:ok, %{status: status, body: body}} ->
        message = if is_map(body), do: body["message"], else: nil

        {:reply,
         Response.text(
           Response.tool(),
           "GitHub search returned #{status}: #{message || "no detail"}"
         ), frame}

      {:error, reason} ->
        {:reply, Response.text(Response.tool(), "GitHub search failed: #{inspect(reason)}"),
         frame}
    end
  end

  # A pull request is an issue carrying a `pull_request` key. Without this the
  # only signal is `/pull/` versus `/issues/` inside the URL, which is easy to
  # read past — and the distinction is the point of the search.
  # `state: "closed"` on its own is ambiguous, and the ambiguity inverts the
  # answer: "closed as not_planned three years ago" and "closed as completed last
  # week" are opposite conclusions about whether a bug is real and fixed. Hence
  # `state_reason` and `closed_at`, which the API already returns.
  #
  # `labels` is often the most compact signal in the whole payload — `bug`,
  # `wontfix`, `upstream`, `needs-repro` each answer the question before the body
  # is read — and it costs a few words.
  defp item(i) do
    %{
      type: if(i["pull_request"], do: "pr", else: "issue"),
      state: i["state"],
      state_reason: i["state_reason"],
      closed_at: i["closed_at"],
      updated_at: i["updated_at"],
      labels: Enum.map(i["labels"] || [], & &1["name"]),
      title: i["title"],
      url: i["html_url"],
      user: get_in(i, ["user", "login"]),
      body: body(i["body"])
    }
  end

  # 300 characters used to be the slice, which was enough to tell you an issue
  # existed and never enough to tell you how it was resolved — the question the
  # tool is actually for. Answering "was this fixed upstream" from a search
  # result meant fetching the HTML page anyway, so the search saved nothing.
  # The marker matters as much as the length: a silently cut body reads as a
  # complete one.
  @body_chars 1500

  defp body(nil), do: ""

  defp body(text) when byte_size(text) <= @body_chars, do: text

  defp body(text), do: String.slice(text, 0, @body_chars) <> "\n…[truncated]"

  defp clamp(value, min, max, _default) when is_integer(value),
    do: value |> max(min) |> min(max)

  defp clamp(_value, _min, _max, default), do: default

  defp headers do
    token = Application.get_env(:stdio_mcp, :github_token)
    base = [{"user-agent", "stdio_mcp/1.0"}]
    if token && token != "", do: [{"authorization", "Bearer #{token}"} | base], else: base
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil
end

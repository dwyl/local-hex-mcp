defmodule StdioMcp.Docs.HexPackage do
  @moduledoc """
  Package metadata from the Hex API.

  One request answers every version question we have — which release is current,
  which releases exist, and where the docs live — so it is fetched once and
  passed around rather than re-derived. Reading a single field and discarding the
  body is how `docs_html_url` went unused and how `latest_stable_version` was
  never consulted.
  """
  require Logger

  @user_agent {"user-agent", "stdio_mcp/1.0"}

  # Short on purpose: this now sits on the search path, not only on ingestion.
  # Req's default receive_timeout is 15s, which against a hung Hex would blow the
  # whole request budget (Anubis' session call gives up at 30s) on a query that
  # could have been served from cache.
  @timeout 2_000

  @type t :: %__MODULE__{
          name: String.t(),
          latest_stable: String.t() | nil,
          latest: String.t() | nil,
          versions: [String.t()],
          docs_url: String.t() | nil,
          github_url: String.t() | nil
        }

  defstruct [:name, :latest_stable, :latest, :docs_url, :github_url, versions: []]

  @doc """
  Fetches metadata for `package`.

  Returns `{:error, reason}` rather than raising: this runs on the search path,
  so an unreachable Hex must degrade to "no version advice", never to a failed
  search.
  """
  @spec fetch(String.t()) :: {:ok, t()} | {:error, term()}
  def fetch(package) when is_binary(package) do
    url = "#{api_url()}/packages/#{package}"

    case Req.get(url, headers: [@user_agent], receive_timeout: @timeout, retry: false) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse(package, body)}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        Logger.warning("[HexPackage] #{package} lookup failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  The version "latest" should mean.

  `latest_version` is the newest release *including pre-releases*, which is not
  what anyone asking for "latest" wants: ex_mcp's newest is 1.0.0-rc.4 while
  hexdocs.pm itself serves 0.12.0. The fallbacks cover packages that have only
  ever published pre-releases, where there is no stable release to prefer.
  """
  @spec latest(t()) :: String.t() | nil
  def latest(%__MODULE__{} = meta) do
    meta.latest_stable || meta.latest || List.first(meta.versions)
  end

  @doc "Whether `version` is a published release of this package."
  @spec published?(t(), String.t()) :: boolean()
  def published?(%__MODULE__{versions: versions}, version), do: version in versions

  defp parse(package, body) do
    %__MODULE__{
      name: package,
      latest_stable: body["latest_stable_version"],
      latest: body["latest_version"],
      docs_url: body["docs_html_url"],
      github_url: github_url(body),
      versions:
        body |> Map.get("releases", []) |> Enum.map(& &1["version"]) |> Enum.reject(&is_nil/1)
    }
  end

  # Free: `meta.links` rides along on the call `fetch/1` already makes for version
  # resolution, so this costs no extra request.
  #
  # Scanned case-insensitively by *value* rather than looked up by key, because
  # the key is not stable — phoenix publishes `"github"`, everyone else checked
  # publishes `"GitHub"`. And the repository is not derivable from the package
  # name, which is the whole reason this is worth carrying:
  #
  #     boruta        -> malach-it/boruta_auth
  #     anubis_mcp    -> zoedsoupe/anubis-mcp        (different org, hyphenated)
  #     text_chunker  -> revelrylabs/text_chunker_ex
  #     req           -> wojtekmach/req              (a personal account, no org)
  #
  # `search_github_issues` currently requires `org:`, which is precisely the
  # argument a caller cannot guess.
  defp github_url(body) do
    body
    |> get_in(["meta", "links"])
    |> Kernel.||(%{})
    |> Enum.find_value(fn {_key, value} ->
      if is_binary(value) and String.contains?(String.downcase(value), "github.com"),
        do: String.trim_trailing(value, "/")
    end)
  end

  defp api_url do
    :stdio_mcp
    |> Application.get_env(:hex_api_url, "https://hex.pm/api")
    |> String.trim_trailing("/")
  end
end

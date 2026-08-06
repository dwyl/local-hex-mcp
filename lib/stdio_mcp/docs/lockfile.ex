defmodule StdioMcp.Docs.Lockfile do
  @moduledoc """
  Reads the *calling project's* `mix.lock`, located by `PROJECT_ROOT`.

  This closes the gap that made version handling awkward: the server runs from
  its own directory — `.mcp.json` does `cd /path/to/local_hex_mcp` — so
  `:application.get_key/2` reports *this* server's dependencies, never the repo
  being edited. Without it, `"latest"` fell through to Hex's latest stable, which
  may be a different major line than the caller compiles against, and the only
  remedy was for the caller to pass `version` on every single call.

  One line of configuration replaces that discipline entirely:

      "env": {
        "DATABASE_PATH": "/Users/x/myapp/.hex_local/mcp.db",
        "PROJECT_ROOT":  "/Users/x/myapp"
      }

  ## Read on every lookup, never cached

  Caching at boot would be marginally faster and wrong: `mix deps.get` or a new
  dependency changes the file mid-session, and a cached map would keep answering
  with versions the project no longer uses until the server restarted — a stale
  answer that looks authoritative. A local file read costs microseconds and the
  result is always current.

  ## Parsed by pattern, not evaluated

  `mix.lock` is an Elixir term, and `Code.eval_string/1` would run whatever it
  contains. The file is trusted in practice, but nothing here needs the risk: the
  entries have a fixed shape and a regex reads them without executing anything.
  """

  require Logger

  # "package": {:hex, :package, "1.2.3", ...} — the `:hex` marker skips `:git`
  # and `:path` entries, which have no Hex version to resolve against.
  @entry ~r/"([a-z0-9_]+)":\s*\{:hex,\s*:[a-z0-9_]+,\s*"([^"]+)"/

  @doc """
  The version `package` is locked to, or `nil` when nothing local pins it.

  `nil` covers every ordinary case: no `PROJECT_ROOT`, no lockfile at that path,
  or a package the project does not depend on.
  """
  @spec version(String.t()) :: String.t() | nil
  def version(package) when is_binary(package) do
    case path() do
      nil -> nil
      path -> path |> read() |> Map.get(package)
    end
  end

  @doc "Every locked package, for diagnostics. Empty when there is no lockfile."
  @spec versions() :: %{String.t() => String.t()}
  def versions do
    case path() do
      nil -> %{}
      path -> read(path)
    end
  end

  @doc "The configured lockfile path, or `nil` when `PROJECT_ROOT` is unset."
  @spec path() :: String.t() | nil
  def path do
    case System.get_env("PROJECT_ROOT") do
      root when is_binary(root) and root != "" -> Path.join(root, "mix.lock")
      _ -> nil
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} ->
        @entry
        |> Regex.scan(contents)
        |> Map.new(fn [_full, package, version] -> {package, version} end)

      {:error, reason} ->
        # Not an error worth failing a search over — a misconfigured PROJECT_ROOT
        # should degrade to the previous behaviour, not break retrieval.
        Logger.warning("[Lockfile] could not read #{path}: #{:file.format_error(reason)}")
        %{}
    end
  end
end

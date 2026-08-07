defmodule StdioMcp.Tools.ListIndexedPackages do
  @moduledoc """
  Lists the packages and versions currently indexed in this database.

  Every version decision `search_docs` makes is otherwise invisible: which
  version is stored, whether its embeddings are complete, and whether anything
  local is pinning it. Without that, `refresh: true` is a guess — it replaces
  whatever is stored, and only one version per package is kept.

  One caveat on `app_version`: it reports the dependencies of the directory this
  server was started from, **not** the repo you are editing, which the server
  cannot see. A `null` there means `"latest"` resolves to Hex's latest stable for
  that package, so pass `version` explicitly if your lockfile says otherwise.
  """

  use Anubis.Server.Component, type: :tool

  import Ecto.Query

  alias Anubis.Server.Response
  alias StdioMcp.AI.Client
  alias StdioMcp.Docs.EmbeddingConfig
  alias StdioMcp.Docs.HexPackage
  alias StdioMcp.PackageDoc
  alias StdioMcp.Repo

  schema do
    field(:check_hex, :boolean,
      description:
        "Optional. When true, also asks Hex for the latest release of every indexed package to flag drift. Costs one HTTP request per package, so it is off by default."
    )
  end

  @impl true
  def execute(params, frame) do
    check_hex = params[:check_hex] || false

    packages =
      Repo.all(
        from(d in PackageDoc,
          group_by: [d.package, d.version],
          order_by: d.package,
          select: %{
            package: d.package,
            version: d.version,
            docs: count(d.id),
            missing_embeddings:
              fragment("SUM(CASE WHEN ? IS NULL THEN 1 ELSE 0 END)", d.embedding),
            last_indexed: max(d.updated_at)
          }
        )
      )
      |> Enum.map(&annotate(&1, check_hex))

    payload = %{
      database: database_path(),
      embedding: embedding_info(),
      packages: packages,
      total_packages: length(packages),
      total_docs: Enum.sum(Enum.map(packages, & &1.docs))
    }

    {:reply, Response.text(Response.tool(), Jason.encode!(payload)), frame}
  rescue
    e ->
      require Logger

      Logger.error(
        "[ListIndexedPackages] Tool execution failed:\n#{Exception.format(:error, e, __STACKTRACE__)}"
      )

      {:reply, Response.text(Response.tool(), "Listing failed: #{Exception.message(e)}"), frame}
  end

  # Which model built the vectors decides whether semantic ranking works at all,
  # and it used to be visible nowhere: the only way to learn it was to count the
  # commas in a stored JSON array. An index built by one model and queried by
  # another either raises inside sqlite-vec — rescued by `Docs.Search` into a
  # silent FTS-only search — or, at equal width, returns noise while raising
  # nothing. `matches_config?: false` is that condition, stated before it can be
  # mistaken for bad ranking.
  defp embedding_info do
    current = Client.embed_model()

    case EmbeddingConfig.get() do
      nil ->
        %{
          index_model: nil,
          query_model: current,
          note:
            "This index predates embedding-model tracking, so what built it is " <>
              "unknown. `mix docs.reindex` re-embeds everything and records it."
        }

      %{model: model, dims: dims} ->
        %{index_model: model, dims: dims, query_model: current, matches_config?: model == current}
    end
  end

  # `app_version` is the version loaded in *this server's* BEAM — the deps of the
  # directory the server was started from, not of the repo the caller is editing.
  # For a package the server does not itself depend on it is nil, and "latest"
  # resolves to Hex latest stable instead, which may not match the caller's
  # lockfile. Showing it is what makes that distinction visible.
  defp annotate(row, check_hex) do
    row
    |> Map.put(:app_version, app_version(row.package))
    |> Map.put(:complete?, row.missing_embeddings == 0)
    |> maybe_check_hex(check_hex)
  end

  defp maybe_check_hex(row, false), do: row

  defp maybe_check_hex(row, true) do
    case HexPackage.fetch(row.package) do
      {:ok, meta} ->
        latest = HexPackage.latest(meta)

        row
        |> Map.put(:hex_latest_stable, latest)
        |> Map.put(:drift, drift(row.version, latest))

      {:error, reason} ->
        Map.put(row, :hex_latest_stable, "unavailable: #{inspect(reason)}")
    end
  end

  defp drift(_stored, nil), do: "unknown"

  defp drift(stored, latest) do
    case Version.compare(stored, latest) do
      :eq -> "current"
      :lt -> "behind — refresh: true moves to #{latest}"
      :gt -> "ahead of stable #{latest} (pre-release) — refresh without version would move back"
    end
  rescue
    Version.InvalidVersionError -> "unknown"
  end

  defp app_version(package) do
    case :application.get_key(String.to_existing_atom(package), :vsn) do
      {:ok, vsn} -> to_string(vsn)
      :undefined -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # Surfacing the file matters when the same server is pointed at several
  # projects: DATABASE_PATH decides whose index this is, and one version per
  # package means two projects sharing a path overwrite each other.
  defp database_path do
    :stdio_mcp
    |> Application.get_env(StdioMcp.Repo, [])
    |> Keyword.get(:database, "unknown")
    |> to_string()
  end
end

defmodule Mix.Tasks.Docs.Sources do
  @shortdoc "Backfills source_url on indexed rows without re-embedding."

  @moduledoc """
  Populates `source_url` for packages indexed before the column existed.

  A source link has no effect on the vector, so `mix docs.reindex` would be the
  wrong instrument: it re-embeds every document to write one metadata field.
  This re-downloads the tarball, re-derives the links, and updates by
  `hexdocs_url` — no embedding calls at all.

  Coverage is uneven by design: only `function`, `callback`, `type` and `macro`
  refs carry an anchor ExDoc attaches a source link to, and a package that does
  not configure `source_url` in its docs config emits none.

      mix docs.sources
      mix docs.sources --only phoenix
  """

  use Mix.Task

  import Ecto.Query

  alias StdioMcp.Docs.TarballIngestion
  alias StdioMcp.PackageDoc
  alias StdioMcp.Repo

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [only: :string])
    Mix.Task.run("app.start")

    Repo.all(
      from(d in PackageDoc,
        group_by: [d.package, d.version],
        order_by: [asc: d.package],
        select: {d.package, d.version}
      )
    )
    |> filter(Keyword.get(opts, :only))
    |> Enum.each(&backfill/1)
  end

  defp filter(targets, nil), do: targets

  defp filter(targets, names) do
    wanted = names |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> MapSet.new()
    Enum.filter(targets, &MapSet.member?(wanted, elem(&1, 0)))
  end

  defp backfill({package, version}) do
    case TarballIngestion.dry_run(package, version) do
      {:ok, docs} ->
        updated =
          docs
          |> Enum.reject(&(&1.source_url in [nil, ""]))
          |> Enum.uniq_by(& &1.hexdocs_url)
          |> Enum.reduce(0, fn doc, acc ->
            {n, _} =
              Repo.update_all(
                from(d in PackageDoc,
                  where: d.package == ^package and d.hexdocs_url == ^doc.hexdocs_url
                ),
                set: [source_url: doc.source_url]
              )

            acc + n
          end)

        Mix.shell().info("  #{String.pad_trailing(package, 16)} #{updated} rows linked")

      {:error, reason} ->
        Mix.shell().error("  #{String.pad_trailing(package, 16)} FAILED #{inspect(reason)}")
    end
  end
end

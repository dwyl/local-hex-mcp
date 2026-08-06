defmodule Mix.Tasks.Docs.Drift do
  @shortdoc "Reports whether a re-ingest would change anything, without spending an embedding."

  @moduledoc """
  Compares what is stored against what today's ingestion code would produce.

  The reflex answer to any change in `SectionChunker` or `TarballIngestion` is to
  re-index everything, and re-indexing costs a full re-embed of every package —
  minutes and real money. Most of the time the answer is that nothing would
  change. This makes that answerable for free.

  It calls `TarballIngestion.dry_run/3`, which walks the identical path — download,
  extract, read the shipped index, resolve each item's content, chunk — and stops
  before embedding. The resulting text is compared to the stored `content`.

  ## What a difference means

  A row reported as **new** is text today's code would write that is not stored,
  and a row reported as **gone** is stored text today's code would no longer
  produce. Either means the package is chunked by superseded code and a refresh
  would genuinely change the index.

  Note that this compares *text only*. It cannot see a change to `embed_text/1`,
  to the embedding model, or to anything else that affects the vector rather than
  the chunk — those need `mix docs.reindex` regardless, and
  `list_indexed_packages` reports the model actually used.

  ## Usage

      mix docs.drift
      mix docs.drift --only phoenix,req
      mix docs.drift --verbose

  ## Options

    * `--only` — comma-separated package names; default is every indexed package
    * `--verbose` — print an excerpt of each differing chunk
  """

  use Mix.Task

  import Ecto.Query

  alias StdioMcp.Docs.TarballIngestion
  alias StdioMcp.PackageDoc
  alias StdioMcp.Repo

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [only: :string, verbose: :boolean])

    Mix.Task.run("app.start")

    case targets(Keyword.get(opts, :only)) do
      [] -> Mix.shell().info("Nothing indexed — nothing to compare.")
      targets -> targets |> Enum.map(&compare(&1, opts)) |> report()
    end
  end

  defp targets(nil), do: indexed()

  defp targets(names) do
    wanted = names |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> MapSet.new()

    case Enum.filter(indexed(), &MapSet.member?(wanted, elem(&1, 0))) do
      [] -> Mix.raise("none of #{inspect(MapSet.to_list(wanted))} are indexed")
      found -> found
    end
  end

  defp indexed do
    Repo.all(
      from(d in PackageDoc,
        group_by: [d.package, d.version],
        order_by: [asc: d.package],
        select: {d.package, d.version}
      )
    )
  end

  defp compare({package, version}, opts) do
    Mix.shell().info("  #{package} #{version} …")

    case TarballIngestion.dry_run(package, version) do
      {:ok, docs} ->
        would = docs |> Enum.map(& &1.content) |> MapSet.new()
        stored = package |> stored_contents() |> MapSet.new()

        result = %{
          package: package,
          version: version,
          would: MapSet.size(would),
          stored: MapSet.size(stored),
          new: MapSet.difference(would, stored),
          gone: MapSet.difference(stored, would)
        }

        if Keyword.get(opts, :verbose, false), do: show(result)
        result

      {:error, reason} ->
        %{package: package, version: version, error: reason}
    end
  end

  defp stored_contents(package) do
    Repo.all(from(d in PackageDoc, where: d.package == ^package, select: d.content))
  end

  defp show(%{new: new, gone: gone}) do
    Enum.each(Enum.take(new, 3), &excerpt("would add", &1))
    Enum.each(Enum.take(gone, 3), &excerpt("would drop", &1))
  end

  defp excerpt(label, text) do
    Mix.shell().info(
      "      #{label}: #{text |> String.replace(~r/\s+/, " ") |> String.slice(0, 90)}"
    )
  end

  defp report(results) do
    Mix.shell().info("")

    Enum.each(results, fn
      %{error: reason, package: package} ->
        Mix.shell().error("  #{String.pad_trailing(package, 16)} FAILED  #{inspect(reason)}")

      %{new: new, gone: gone} = r ->
        n = MapSet.size(new)
        g = MapSet.size(gone)

        line =
          "  #{String.pad_trailing(r.package, 16)} #{String.pad_leading("#{r.stored}", 5)} stored"

        if n == 0 and g == 0,
          do: Mix.shell().info(line <> "   identical"),
          else: Mix.shell().error(line <> "   #{n} new, #{g} gone  ← refresh would change this")
    end)

    drifted = Enum.count(results, &(is_map_key(&1, :new) and drifted?(&1)))

    Mix.shell().info("")

    if drifted == 0 do
      Mix.shell().info(
        "Every package matches what today's code produces. A refresh is a no-op.\n"
      )
    else
      Mix.shell().error(
        "#{drifted} package(s) would change. `mix docs.reindex --only <names>` to bring them " <>
          "forward; that re-embeds them, so it is not free.\n"
      )
    end
  end

  defp drifted?(%{new: new, gone: gone}),
    do: MapSet.size(new) > 0 or MapSet.size(gone) > 0
end

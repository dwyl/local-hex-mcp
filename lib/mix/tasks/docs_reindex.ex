defmodule Mix.Tasks.Docs.Reindex do
  @shortdoc "Re-embeds every indexed package under the currently configured model."

  @moduledoc """
  Rebuilds the whole vector index under `AI_EMBED_MODEL`.

  This is the supported way to change embedding models, and the only one.
  Embeddings from two models are not comparable — different dimensions make
  sqlite-vec raise, identical dimensions make it return noise — so
  `TarballIngestion.ingest/3` refuses to write vectors from a model other than
  the one already recorded in `embedding_config`. That refusal is what keeps the
  index single-model; this task is what lets you change your mind about which
  model that is.

  Re-embedding every row is unavoidable, not an artefact of how the vectors are
  stored. A 1024-dimension index and a 1536-dimension index are different vector
  spaces and there is no conversion between them, so switching models always
  costs one full pass over every indexed package.

  ## Partial failure deletes rather than keeps

  If a package fails to re-ingest, its **old rows are deleted**. Keeping them
  would leave the index holding vectors from two models — the exact state this
  whole mechanism exists to prevent — and it would be an invisible state, since
  the `embedding_config` row would by then name the new model. Deletion is safe
  because `Docs.Search` re-ingests a missing package on the next search, so a
  failure costs one slow query later rather than a corrupt index forever.

  Pass `--keep-failed` to override, accepting a mixed index.

  ## Usage

      mix docs.reindex
      mix docs.reindex --only boruta,req
      mix docs.reindex --yes

  ## Options

    * `--only` — comma-separated package names; default is every indexed package
    * `--yes` — skip the confirmation prompt
    * `--keep-failed` — leave stale rows in place when a package fails
  """

  use Mix.Task

  import Ecto.Query

  alias StdioMcp.AI.Client
  alias StdioMcp.Docs.EmbeddingConfig
  alias StdioMcp.Docs.TarballIngestion
  alias StdioMcp.PackageDoc
  alias StdioMcp.Repo

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv, strict: [only: :string, yes: :boolean, keep_failed: :boolean])

    Mix.Task.run("app.start")

    model = Client.embed_model()
    targets = opts |> Keyword.get(:only) |> targets()

    case targets do
      [] ->
        Mix.shell().info("Nothing indexed — nothing to reindex.")

      targets ->
        if confirm?(targets, model, opts), do: reindex(targets, model, opts)
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
        select: {d.package, d.version, count(d.id)}
      )
    )
  end

  # Re-embedding is the expensive, billable half of ingestion, so the count and
  # the model both get stated before anything is spent — the failure mode this
  # whole feature exists for is a model nobody noticed was in effect.
  defp confirm?(targets, model, opts) do
    total = targets |> Enum.map(&elem(&1, 2)) |> Enum.sum()

    Mix.shell().info("""

    Re-embedding #{length(targets)} package(s), #{total} docs, with #{model}.
    #{describe_current()}
    """)

    Enum.each(targets, fn {package, version, count} ->
      Mix.shell().info(
        "  #{String.pad_trailing(package, 16)} #{String.pad_trailing(version, 16)} #{count} docs"
      )
    end)

    Mix.shell().info("")

    Keyword.get(opts, :yes, false) or Mix.shell().yes?("Proceed?")
  end

  defp describe_current do
    case EmbeddingConfig.get() do
      nil -> "The index has no recorded model (built before embedding_config existed)."
      %{model: model, dims: dims} -> "Currently recorded: #{model} (#{dims} dims)."
    end
  end

  # Cleared first, and only here: an empty record is what lets the next ingestion
  # adopt a new model, and it is only safe when every package is about to be
  # re-embedded. The first successful ingest writes the new record; the rest are
  # then checked against it, so a model changing mid-run still cannot produce a
  # mixed index.
  defp reindex(targets, model, opts) do
    :ok = EmbeddingConfig.clear()

    results =
      Enum.map(targets, fn {package, version, _count} ->
        Mix.shell().info("  #{package} #{version} …")
        {package, version, ingest(package, version, opts)}
      end)

    report(results, model)
  end

  defp ingest(package, version, opts) do
    case TarballIngestion.ingest(package, version) do
      {:ok, count, _version} ->
        {:ok, count}

      {:error, reason} ->
        unless Keyword.get(opts, :keep_failed, false), do: drop(package)
        {:error, reason}
    end
  rescue
    e ->
      unless Keyword.get(opts, :keep_failed, false), do: drop(package)
      {:error, Exception.message(e)}
  end

  defp drop(package) do
    {deleted, _} = Repo.delete_all(from(d in PackageDoc, where: d.package == ^package))
    Mix.shell().error("    dropped #{deleted} stale rows — will re-ingest on next search")
  end

  defp report(results, model) do
    {ok, failed} = Enum.split_with(results, &match?({_p, _v, {:ok, _}}, &1))

    Mix.shell().info("""

    #{length(ok)} package(s) re-embedded with #{model}.\
    """)

    case failed do
      [] ->
        Mix.shell().info("Index is single-model.\n")

      failed ->
        Enum.each(failed, fn {package, version, {:error, reason}} ->
          Mix.shell().error("  FAILED #{package} #{version}: #{inspect(reason)}")
        end)

        Mix.shell().error(
          "\nThose packages are no longer indexed. They re-ingest automatically on " <>
            "the next search that names them.\n"
        )
    end
  end
end

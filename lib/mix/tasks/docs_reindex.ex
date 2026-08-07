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
  alias StdioMcp.Knowledge
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
        refuse_partial_model_change(opts, model)
        if confirm?(targets, model, opts), do: reindex(targets, model, opts)
    end
  end

  # `--only` re-embeds a subset but `EmbeddingConfig.clear/0` is global, so under a
  # *changed* model it produces precisely the state this task exists to prevent:
  # the named packages on the new model, every other package on the old one, and
  # one record claiming the new model for all of them. Nothing raises at matching
  # dimensions.
  #
  # `--only` is for re-embedding a package that failed, under the model already in
  # force. Changing the model is all-or-nothing by construction.
  defp refuse_partial_model_change(opts, model) do
    with names when is_binary(names) <- Keyword.get(opts, :only),
         %{model: stored} when stored != model <- EmbeddingConfig.get() do
      Mix.raise("""
      --only #{names} would change the embedding model for part of the index.

        recorded: #{stored}
        current:  #{model}

      That leaves the other packages on '#{stored}' while the record names
      '#{model}', and comparing vectors across two models fails silently rather
      than raising. Run `mix docs.reindex` with no --only to change models, or set
      AI_EMBED_MODEL back to '#{stored}' to re-embed just these packages.
      """)
    else
      _ -> :ok
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
  #
  # Then every target's rows are deleted before any of them is re-embedded, which
  # is the difference between a *failed* package and an *interrupted* run. A
  # failure is handled below by dropping that package's rows; an interruption —
  # Ctrl-C, a killed process, the embedding endpoint going down — never reaches
  # that code, so it used to leave the packages already done on the new model,
  # every package not yet reached on the old one, and the record naming the new
  # one. Search then compares the query against both, and at matching dimensions
  # nothing raises: it is the silent mixed index this whole mechanism exists to
  # prevent, reachable by pressing Ctrl-C.
  #
  # Purging up front means an interruption leaves the untouched packages *absent*
  # instead of stale, and absent is safe — `Docs.Search` re-ingests a missing
  # package on the next search that names it. The cost is that a run which fails
  # outright empties the index rather than leaving it usable, which is what
  # `--keep-failed` is for.
  defp reindex(targets, model, opts) do
    :ok = EmbeddingConfig.clear()

    unless Keyword.get(opts, :keep_failed, false), do: purge(targets)

    results =
      Enum.map(targets, fn {package, version, _count} ->
        Mix.shell().info("  #{package} #{version} …")
        {package, version, ingest(package, version, opts)}
      end)

    knowledge = reindex_knowledge(model)

    report(results, knowledge, model)
  end

  defp purge(targets) do
    names = Enum.map(targets, &elem(&1, 0))
    {deleted, _} = Repo.delete_all(from(d in PackageDoc, where: d.package in ^names))

    Mix.shell().info(
      "  cleared #{deleted} rows up front — an interrupted run leaves no mixed index\n"
    )
  end

  # The knowledge base is a second vector space in the same database, embedded by
  # the same `Client.embed/1` and compared with the same `vec_distance_cosine`,
  # and it was not re-embedded here — so changing `AI_EMBED_MODEL` used to move
  # `package_docs` to the new model and leave `knowledge` on the old one, with one
  # `embedding_config` row describing both. `Memory.search/2` is FTS-only and was
  # unaffected, but `process_remember/2` finds neighbours by cosine and applies a
  # similarity threshold to them, so deduplication was deciding on noise.
  #
  # Small enough to do in one batch and not worth a separate task: a knowledge
  # base is tens of rows where a package is thousands.
  defp reindex_knowledge(model) do
    case Repo.all(from(k in Knowledge, select: {k.id, k.content})) do
      [] ->
        {:ok, 0}

      rows ->
        Mix.shell().info("  knowledge #{length(rows)} entries …")
        embed_knowledge(rows, model)
    end
  end

  defp embed_knowledge(rows, _model) do
    {ids, contents} = Enum.unzip(rows)

    case Client.embed_batch(contents) do
      {:ok, vectors} ->
        Enum.zip(ids, vectors)
        |> Enum.each(fn {id, vector} ->
          Repo.update_all(from(k in Knowledge, where: k.id == ^id),
            set: [embedding: Jason.encode!(vector)]
          )
        end)

        {:ok, length(ids)}

      {:error, reason} ->
        # Left in place rather than dropped. A knowledge entry is user-authored
        # and cannot be re-derived from anywhere, unlike a package, which is one
        # download away — so a stale vector is the lesser loss, and the mismatch
        # guard in `Memory` degrades the neighbour search instead of trusting it.
        {:error, reason}
    end
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

  defp report(results, knowledge, model) do
    {ok, failed} = Enum.split_with(results, &match?({_p, _v, {:ok, _}}, &1))

    Mix.shell().info("""

    #{length(ok)} package(s) re-embedded with #{model}.#{describe_knowledge(knowledge)}\
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

  # A knowledge failure is reported but does not make the run a failure: the
  # packages are consistent either way, and the entries keep their old vectors,
  # which `Memory` now detects rather than trusting.
  defp describe_knowledge({:ok, 0}), do: ""

  defp describe_knowledge({:ok, n}),
    do: "\n#{n} knowledge entr#{if n == 1, do: "y", else: "ies"} re-embedded."

  defp describe_knowledge({:error, reason}),
    do:
      "\nWARNING: knowledge entries could NOT be re-embedded (#{inspect(reason)}) — " <>
        "they keep vectors from the previous model, and `remember` will skip " <>
        "neighbour search until `mix docs.reindex` succeeds."
end

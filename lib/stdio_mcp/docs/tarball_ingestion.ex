defmodule StdioMcp.Docs.TarballIngestion do
  @moduledoc """
  Ingests a package's documentation from its Hex docs tarball.

  The existing `StdioMcp.Docs.IngestionWorker` reconstructs the documentation by
  scraping hexdocs.pm: it probes for `search_data.js` (which 404s for every
  package tested), falls back to scraping HTML for a `sidebar_items-*.js`
  navigation index that carries no documentation text, and then fetches one HTML
  page per item — 761 requests for `anubis_mcp` alone.

  All of that exists to reconstruct something Hex already publishes. The tarball
  at `https://repo.hex.pm/docs/{package}-{version}.tar.gz` contains:

    * `dist/search_data-*.js` — the real search index, **with** documentation
      text. Present in every package checked, old and new: anubis_mcp 992/1272
      items carry text, phoenix 822/880, jason 79/122.
    * `*.md` — clean markdown of every page. Recent ExDoc only (phoenix, ecto,
      req and jason ship none), so it is a bonus, not the basis.
    * `*.html` — every page, for the thin remainder on older packages.
    * `llms.txt` — a curated index that notably omits generated pages such as
      `api-reference`. Recent ExDoc only.

  So this module makes one HTTP request instead of several hundred, and gets
  better content for it.

  Nothing is written to disk: the tarball is extracted in memory via
  `:erl_tar.extract/2` with `:memory`, and the file map is discarded when
  ingestion returns.
  """

  alias StdioMcp.AI.Client
  alias StdioMcp.Docs.IngestionJob
  alias StdioMcp.PackageDoc
  alias StdioMcp.Repo

  import Ecto.Query
  require Logger

  @chunk_threshold 1500
  @user_agent {"user-agent", "stdio_mcp/1.0"}

  # Req's `:request_timeout` defaults to `:infinity`, and `:receive_timeout`
  # (15s) only bounds the wait for the *next* packet — a server trickling bytes
  # slower than that keeps the request open forever. These are GETs, so Req's
  # default `retry: :safe_transient` also retries them with backoff on top. An
  # explicit ceiling is what stops a wedged fetch from occupying an
  # IngestionJob key permanently.
  @request_timeout 120_000

  # Both tunable via EMBED_BATCH_SIZE / EMBED_CONCURRENCY (see
  # config/runtime.exs) — they depend on the provider's rate limit, not on this
  # code, and are read at call time so a restart picks up a new value.

  # Mistral rate-limits on `requests_per_second` (plus per-model token limits),
  # so the batch size — not the concurrency — is the dominant lever: 5415 docs at
  # 50 per request is 109 requests, at 200 it is 28. Bigger still trades request
  # pressure for token pressure, since mistral-embed has an 8k context.
  @default_embed_batch_size 200

  # 4 was measured to exhaust the embedding provider's rate limit on a
  # 109-batch package, failing the whole ingest with 429s. The batches are
  # already the efficient unit, so concurrency past 2 buys little and costs
  # backoff. Bounded above by the Finch pool (size 10), never by CPU count.
  @default_embed_concurrency 2

  defp embed_batch_size do
    Application.get_env(:stdio_mcp, :embed_batch_size, @default_embed_batch_size)
  end

  defp embed_concurrency do
    Application.get_env(:stdio_mcp, :embed_concurrency, @default_embed_concurrency)
  end

  @embed_batch_timeout 180_000
  @embed_max_attempts 5
  @embed_backoff_ms 1_000
  @embed_backoff_max_ms 30_000

  @doc """
  Ingests `package` at `version` ("latest" resolves via the Hex API).

  Returns `{:ok, rows_written, resolved_version}`.
  """
  def ingest(package, version \\ "latest") when is_binary(package) do
    with {:ok, resolved} <- resolve_version(package, version),
         :ok <- IngestionJob.stage(:downloading),
         {:ok, tarball} <- download(package, resolved),
         {:ok, files} <- extract(tarball),
         {:ok, items} <- read_index(files) do
      base_url = "https://hexdocs.pm/#{package}/#{resolved}"

      docs = Enum.flat_map(items, &build_docs(&1, files, base_url))

      # Embedding failure aborts the ingest instead of saving. Persisting rows
      # with nil embeddings writes an index that looks complete, passes every
      # count check, and is invisible to vector search — a silent, permanent
      # quality loss that only a re-ingest can undo.
      with {:ok, embedded} <- attach_embeddings(docs) do
        IngestionJob.stage(:saving)

        case save(embedded, package, resolved) do
          {:ok, count} -> {:ok, count, resolved}
          error -> error
        end
      end
    end
  end

  # -- Acquisition ------------------------------------------------------------

  defp resolve_version(package, "latest") do
    case Req.get("https://hex.pm/api/packages/#{package}",
           headers: [@user_agent],
           request_timeout: @request_timeout
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, get_in(body, ["releases", Access.at(0), "version"]) || "latest"}

      _ ->
        {:error, :version_not_resolved}
    end
  end

  defp resolve_version(_package, version), do: {:ok, version}

  defp download(package, version) do
    url = "https://repo.hex.pm/docs/#{package}-#{version}.tar.gz"

    # `decode_body: false` keeps the gzipped tar intact; Req would otherwise try
    # to interpret it based on content-type.
    case Req.get(url,
           headers: [@user_agent],
           decode_body: false,
           redirect: :follow,
           request_timeout: @request_timeout
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:tarball_unavailable, status}}

      {:error, reason} ->
        {:error, {:download_failed, reason}}
    end
  end

  defp extract(tarball) do
    case :erl_tar.extract({:binary, tarball}, [:memory, :compressed]) do
      {:ok, entries} ->
        {:ok, Map.new(entries, fn {name, content} -> {to_string(name), content} end)}

      {:error, reason} ->
        {:error, {:extract_failed, reason}}
    end
  end

  # -- The index --------------------------------------------------------------

  # `search_data` carries documentation text but only exists on newer ExDoc.
  # Older packages (phoenix 1.3, poison 3.1, plug 1.4, gettext 0.11 …) ship only
  # `sidebar_items`, a navigation tree with no text — for those every item is
  # thin and the content comes from the page files, which the tarball also
  # contains. Either way it is one download and no per-page requests.
  defp read_index(files) do
    cond do
      entry = find_file(files, ~r{^dist/search_data-.*\.js$}) -> parse_search_data(entry)
      entry = find_file(files, ~r{^dist/sidebar_items.*\.js$}) -> parse_sidebar_items(entry)
      true -> {:error, :no_index_in_tarball}
    end
  end

  defp find_file(files, pattern) do
    case Enum.find(files, fn {name, _} -> name =~ pattern end) do
      {_name, content} -> content
      nil -> nil
    end
  end

  defp parse_search_data(js) do
    with [_, json] <- Regex.run(~r/^\s*searchData\s*=\s*(.*)$/s, js),
         {:ok, %{"items" => items}} <- Jason.decode(String.trim_trailing(String.trim(json), ";")) do
      {:ok, items}
    else
      _ -> {:error, :search_data_unparseable}
    end
  end

  # sidebarNodes = {"modules": [...], "extras": [...]}. No documentation text, so
  # every item produced here is deliberately thin and resolved from the page.
  defp parse_sidebar_items(js) do
    with [_, json] <- Regex.run(~r/^\s*sidebarNodes\s*=\s*(.*)$/s, js),
         {:ok, nodes} <- Jason.decode(String.trim_trailing(String.trim(json), ";")) do
      modules = Enum.flat_map(Map.get(nodes, "modules", []), &sidebar_module_items/1)
      extras = Enum.map(Map.get(nodes, "extras", []), &sidebar_extra_item/1)
      {:ok, modules ++ extras}
    else
      _ -> {:error, :sidebar_items_unparseable}
    end
  end

  defp sidebar_module_items(mod) do
    id = Map.get(mod, "id", "")
    title = Map.get(mod, "title", id)

    entries =
      mod
      |> Map.get("nodeGroups", [])
      |> Enum.flat_map(fn group ->
        type = group |> Map.get("key", "function") |> String.trim_trailing("s")

        Enum.map(Map.get(group, "nodes", []), fn node ->
          anchor = Map.get(node, "anchor", Map.get(node, "id", ""))

          %{
            "ref" => "#{id}.html##{anchor}",
            "title" => Map.get(node, "id", anchor),
            "doc" => "",
            "type" => type
          }
        end)
      end)

    [%{"ref" => "#{id}.html", "title" => title, "doc" => "", "type" => "module"} | entries]
  end

  defp sidebar_extra_item(extra) do
    id = Map.get(extra, "id", "")

    %{
      "ref" => "#{id}.html",
      "title" => Map.get(extra, "title", id),
      "doc" => "",
      "type" => "extras"
    }
  end

  # -- Item construction ------------------------------------------------------

  defp build_docs(item, files, base_url) do
    ref = Map.get(item, "ref", "")
    title = Map.get(item, "title", "")
    type = to_string(Map.get(item, "type", "doc"))
    doc = Map.get(item, "doc", "") || ""

    content = if doc != "" and doc != title, do: doc, else: page_content(ref, files)

    if String.trim(content) == "" and String.trim(title) == "" do
      []
    else
      {module, function} = split_ref(ref, title, type)
      url = "#{base_url}/#{ref}"
      chunks = maybe_chunk(content)
      multi? = match?([_, _ | _], chunks)

      Enum.with_index(chunks, fn chunk, idx ->
        %{
          doc_type: type,
          module: module,
          function: function,
          signature: if(multi?, do: "#{title} - Part #{idx + 1}", else: title),
          content: chunk,
          code_snippet: first_code_block(chunk),
          hexdocs_url: url
        }
      end)
    end
  end

  # Falls back to the page when `search_data` has no text for an item, which is
  # 7–36% of items depending on the package. Markdown is preferred where the
  # package ships it; older packages fall through to HTML.
  #
  # The anchor matters in both cases: a ref like `readme.html#overview` refers to
  # one section, so returning the whole page would repeat the entire guide once
  # per section.
  defp page_content(ref, files) do
    {page, anchor} =
      case String.split(ref, "#", parts: 2) do
        [page, anchor] -> {page, anchor}
        [page] -> {page, nil}
      end

    base = String.replace_suffix(page, ".html", "")

    cond do
      md = Map.get(files, base <> ".md") -> markdown_section(md, anchor)
      html = Map.get(files, page) -> html_section(html, anchor)
      true -> ""
    end
  end

  defp split_ref(ref, title, type) do
    page = ref |> String.split("#") |> List.first() |> to_string()
    module = String.replace_suffix(page, ".html", "")

    case type do
      t when t in ~w(function macro callback type) -> {module, title}
      _ -> {module, nil}
    end
  end

  defp maybe_chunk(content) when byte_size(content) <= @chunk_threshold, do: [content]

  defp maybe_chunk(content) do
    case TextChunker.split(content, chunk_size: 400, chunk_overlap: 40, format: :markdown) do
      chunks when is_list(chunks) ->
        Enum.map(chunks, & &1.text)

      other ->
        Logger.warning("[TarballIngestion] chunking failed (#{inspect(other)}) — storing whole")
        [content]
    end
  end

  defp first_code_block(text) do
    case Regex.run(~r/```[a-z]*\n(.*?)```/s, text) do
      [_, code] -> String.trim(code)
      _ -> nil
    end
  end

  defp markdown_section(md, nil), do: md

  # ExDoc slugifies heading text for the anchor, and prefixes moduledoc sections
  # with "module-". Match on either so both guide and module anchors resolve.
  defp markdown_section(md, anchor) do
    lines = String.split(md, "\n")

    start =
      Enum.find_index(lines, fn line ->
        case Regex.run(~r/^\#{1,6}\s+(.*)$/u, line) do
          [_, heading] -> slug(heading) in [anchor, String.replace_prefix(anchor, "module-", "")]
          _ -> false
        end
      end)

    case start do
      nil ->
        md

      start ->
        rest = Enum.drop(lines, start + 1)
        len = Enum.find_index(rest, &Regex.match?(~r/^\#{1,6}\s+/u, &1)) || length(rest)
        [Enum.at(lines, start) | Enum.take(rest, len)] |> Enum.join("\n") |> String.trim()
    end
  end

  defp slug(heading) do
    heading
    |> String.replace(~r/`|\*|_/u, "")
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/u, "")
    |> String.replace(~r/\s+/u, "-")
  end

  # ExDoc wraps the real page body in `<div id="content">`; without isolating it
  # first, stripping tags yields the nav, sidebar and search box rather than the
  # documentation. `<section id="anchor">` narrows further to a single item.
  defp html_section(html, anchor) do
    body =
      case Regex.run(
             ~r/<(?:div|main)[^>]*id=["'](?:content|main)["'][^>]*>(.*)<\/(?:div|main)>/s,
             html
           ) do
        [_, inner] -> inner
        _ -> html
      end

    strip_html(narrow_to_anchor(body, anchor))
  end

  defp narrow_to_anchor(body, nil), do: body

  # Two shapes carry an anchor: `<section id="foo/2">` for function details, and
  # `<h2 id="the-server-module">` for guide and moduledoc sections. Without the
  # second, guide anchors fell through to the whole page and dragged in the
  # surrounding nav — which is how chrome leaked into changelog entries.
  defp narrow_to_anchor(body, anchor) do
    case Regex.run(~r/<section[^>]*id="#{Regex.escape(anchor)}"[^>]*>(.*?)<\/section>/si, body) do
      [_, inner] ->
        inner

      _ ->
        case heading_slice(body, anchor) do
          "" -> body
          slice -> slice
        end
    end
  end

  defp heading_slice(html, anchor) do
    headings =
      ~r/<h([1-6])[^>]*\sid="([^"]+)"/i
      |> Regex.scan(html, return: :index)
      |> Enum.map(fn [{start, _}, {lvl_start, lvl_len}, {id_start, id_len}] ->
        {start, String.to_integer(binary_part(html, lvl_start, lvl_len)),
         binary_part(html, id_start, id_len)}
      end)

    case Enum.find_index(headings, fn {_start, _lvl, id} -> id == anchor end) do
      nil -> ""
      idx -> slice_from(html, headings, idx)
    end
  end

  # A section runs until the next heading of the same or higher rank: an h2 must
  # swallow its h3 subsections, not stop at the first one. Stopping at any
  # heading left changelog entries as a bare date line.
  defp slice_from(html, headings, idx) do
    {start, level, _} = Enum.at(headings, idx)

    stop =
      headings
      |> Enum.drop(idx + 1)
      |> Enum.find_value(byte_size(html), fn {next_start, next_level, _} ->
        if next_level <= level, do: next_start
      end)

    binary_part(html, start, stop - start)
  end

  defp strip_html(html) do
    html
    |> String.replace(~r/<(script|style)[^>]*>.*?<\/\1>/si, " ")
    |> String.replace(~r/<[^>]+>/, " ")
    |> decode_entities()
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp decode_entities(text) do
    Enum.reduce(
      [
        {"&amp;", "&"},
        {"&lt;", "<"},
        {"&gt;", ">"},
        {"&quot;", "\""},
        {"&#39;", "'"},
        {"&nbsp;", " "}
      ],
      text,
      fn {from, to}, acc -> String.replace(acc, from, to) end
    )
  end

  # -- Persistence ------------------------------------------------------------

  # The embeddings endpoint takes a whole batch per request, so the batches are
  # already the efficient unit — but they used to run one after another, and that
  # sequential wait is essentially the entire ingestion time. Download, extract,
  # parse and insert of a 872-doc package take ~0.5s; the embedding round trips
  # take the other ~45s. Running them concurrently is the difference between
  # finishing inside a caller's wait and not.
  #
  # Concurrency stays modest on purpose: each task holds a Finch connection and
  # every extra in-flight request raises the chance of a 429, which costs more in
  # backoff than the parallelism saves.
  defp attach_embeddings([]), do: {:ok, []}

  defp attach_embeddings(docs) do
    batches = Enum.chunk_every(docs, embed_batch_size())
    total = length(batches)

    batches
    |> Task.async_stream(&embed_batch/1,
      max_concurrency: embed_concurrency(),
      ordered: true,
      timeout: @embed_batch_timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, [], 0}, &collect_batch(&1, &2, total))
    |> case do
      {:ok, acc, _done} -> {:ok, acc |> Enum.reverse() |> Enum.concat()}
      {:error, reason} -> {:error, {:embedding_failed, reason}}
    end
  end

  # Runs in the ingesting process, not the stream tasks, which is what makes the
  # progress update safe: Registry.update_value/3 only writes the *caller's* own
  # registration, so a stage/1 call from inside a task is a silent no-op.
  defp collect_batch({:ok, {:ok, embedded}}, {:ok, acc, done}, total) do
    IngestionJob.stage("embedding #{done + 1}/#{total}")
    {:cont, {:ok, [embedded | acc], done + 1}}
  end

  defp collect_batch({:ok, {:error, reason}}, _acc, _total), do: {:halt, {:error, reason}}
  defp collect_batch({:exit, reason}, _acc, _total), do: {:halt, {:error, {:task_exit, reason}}}

  defp embed_batch(batch, attempt \\ 1) do
    texts = Enum.map(batch, &embed_text/1)

    case Client.embed_batch(texts) do
      # Every vector has to be real. One nil slipping through would persist a row
      # that `Docs.Search.already_ingested?/2` treats as incomplete forever, and
      # the package would re-ingest on every single search.
      {:ok, vectors} when length(vectors) == length(batch) ->
        if Enum.all?(vectors, &is_list/1) do
          {:ok, Enum.zip_with(batch, vectors, &Map.put(&1, :embedding, &2))}
        else
          {:error, :nil_vector_in_response}
        end

      # A short vector list would silently misalign embeddings against docs, and
      # zip_with would drop the tail — worse than failing.
      {:ok, vectors} ->
        {:error, {:vector_count_mismatch, length(vectors), length(batch)}}

      {:error, {429, retry_after_ms}} when attempt < @embed_max_attempts ->
        delay = backoff(retry_after_ms, attempt)
        Logger.warning("[TarballIngestion] embedding rate limited, retrying in #{delay}ms")
        Process.sleep(delay)
        embed_batch(batch, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The server's own Retry-After wins when it sends one — it knows when the
  # window reopens and guessing shorter just burns another attempt. Otherwise
  # back off exponentially: linear 1s/2s/3s steps were measured to be too
  # shallow to outlast a rate-limit window.
  defp backoff(retry_after_ms, _attempt) when is_integer(retry_after_ms) do
    min(retry_after_ms, @embed_backoff_max_ms)
  end

  defp backoff(_retry_after_ms, attempt) do
    min(@embed_backoff_ms * Integer.pow(2, attempt - 1), @embed_backoff_max_ms)
  end

  defp embed_text(doc) do
    [doc.module, doc.function, doc.signature, doc.content]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp save(docs, package, version) do
    Repo.transaction(fn ->
      Repo.delete_all(
        from(d in PackageDoc, where: d.package == ^package and d.version == ^version)
      )

      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      docs
      |> Enum.map(fn doc ->
        doc
        |> Map.take([
          :doc_type,
          :module,
          :function,
          :signature,
          :content,
          :code_snippet,
          :hexdocs_url
        ])
        |> Map.merge(%{
          package: package,
          version: version,
          embedding: if(doc.embedding, do: Jason.encode!(doc.embedding)),
          inserted_at: now,
          updated_at: now
        })
      end)
      |> Enum.chunk_every(100)
      |> Enum.reduce(0, fn batch, acc ->
        {n, _} = Repo.insert_all(PackageDoc, batch)
        acc + n
      end)
    end)
    |> case do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, {:save_failed, reason}}
    end
  end
end

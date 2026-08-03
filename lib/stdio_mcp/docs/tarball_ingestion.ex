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
  alias StdioMcp.PackageDoc
  alias StdioMcp.Repo

  import Ecto.Query
  require Logger

  @chunk_threshold 1500
  @user_agent {"user-agent", "stdio_mcp/1.0"}

  @doc """
  Ingests `package` at `version` ("latest" resolves via the Hex API).

  Returns `{:ok, rows_written, resolved_version}`.
  """
  def ingest(package, version \\ "latest") when is_binary(package) do
    with {:ok, resolved} <- resolve_version(package, version),
         {:ok, tarball} <- download(package, resolved),
         {:ok, files} <- extract(tarball),
         {:ok, items} <- read_index(files) do
      base_url = "https://hexdocs.pm/#{package}/#{resolved}"

      docs =
        items
        |> Enum.flat_map(&build_docs(&1, files, base_url))
        |> attach_embeddings()

      case save(docs, package, resolved) do
        {:ok, count} -> {:ok, count, resolved}
        error -> error
      end
    end
  end

  # -- Acquisition ------------------------------------------------------------

  defp resolve_version(package, "latest") do
    case Req.get("https://hex.pm/api/packages/#{package}", headers: [@user_agent]) do
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
    case Req.get(url, headers: [@user_agent], decode_body: false, redirect: :follow) do
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

  defp attach_embeddings(docs) do
    docs
    |> Enum.chunk_every(50)
    |> Enum.flat_map(fn batch ->
      texts = Enum.map(batch, &embed_text/1)

      case Client.embed_batch(texts) do
        {:ok, vectors} ->
          Enum.zip_with(batch, vectors, &Map.put(&1, :embedding, &2))

        {:error, reason} ->
          Logger.warning("[TarballIngestion] embedding batch failed: #{inspect(reason)}")
          Enum.map(batch, &Map.put(&1, :embedding, nil))
      end
    end)
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

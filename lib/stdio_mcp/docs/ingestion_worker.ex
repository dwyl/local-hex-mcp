defmodule StdioMcp.Docs.IngestionWorker do
  @moduledoc "Ported HexDocs worker supporting sidebarNodes, search_data, and TextChunker for SQLite."
  import Ecto.Query
  alias StdioMcp.AI.Client
  alias StdioMcp.PackageDoc
  alias StdioMcp.Repo
  require Logger

  def ingest(package, version \\ "latest") when is_binary(package) do
    key = {__MODULE__, package}

    case Registry.register(StdioMcp.IngestionRegistry, key, :running) do
      {:ok, _} ->
        try do
          do_ingest(package, version)
        after
          Registry.unregister(StdioMcp.IngestionRegistry, key)
        end

      {:error, {:already_registered, _}} ->
        Logger.info("[IngestionWorker] skipping #{package} — already ingesting")
        {:error, :already_ingesting}
    end
  end

  defp do_ingest(package, version) do
    with {:ok, canonical, resolved_version, docs_url} <- resolve_package(package, version) do
      case fetch_search_data(canonical, resolved_version) do
        {:ok, search_data} ->
          ingest_search_data(search_data, canonical, resolved_version, docs_url)

        {:error, _reason} when docs_url != nil ->
          ingest_served_version(canonical, resolved_version, docs_url)

        error ->
          error
      end
    end
  end

  # The latest release may have no published docs. HexDocs still serves an
  # earlier version, so ask which one and retry against that before giving up.
  defp ingest_served_version(canonical, resolved_version, docs_url) do
    case detect_served_version(docs_url) do
      {:ok, served_version} when served_version != resolved_version ->
        retry_with_version(canonical, resolved_version, served_version, docs_url)

      _ ->
        {:error, {:no_docs, resolved_version}}
    end
  end

  defp retry_with_version(canonical, resolved_version, served_version, docs_url) do
    Logger.info(
      "[IngestionWorker] no docs for #{canonical} v#{resolved_version}, " <>
        "falling back to served v#{served_version}"
    )

    # A bare `with` returns the unmatched value, preserving the fetch error
    # rather than flattening it into {:no_docs, _}.
    with {:ok, search_data} <- fetch_search_data(canonical, served_version) do
      ingest_search_data(search_data, canonical, served_version, docs_url)
    end
  end

  defp ingest_search_data(search_data, canonical, version, docs_url) do
    items = Map.get(search_data, "items", [])
    base_url = build_base_url(docs_url, canonical, version)

    docs =
      items
      |> Enum.flat_map(&build_doc_items(canonical, version, base_url, &1))
      |> Enum.reject(&is_nil/1)

    docs_with_embeddings = attach_embeddings_batch(docs)
    save_docs(docs_with_embeddings, canonical, version)

    # Clear per-page HTML cache from process dictionary
    Process.get_keys()
    |> Enum.filter(&match?({:html_cache, _}, &1))
    |> Enum.each(&Process.delete/1)

    {:ok, length(docs), version}
  end

  @doc """
  Detects the version actually served by a HexDocs URL by reading the HTML title.
  E.g. `<title>ex_mcp v0.12.0 — Documentation</title>` → "0.12.0"
  """
  def detect_served_version(docs_url) do
    url = String.trim_trailing(docs_url, "/")

    case Req.get(url, headers: [{"user-agent", "stdio_mcp/1.0"}], redirect: :follow) do
      {:ok, %{status: 200, body: html}} when is_binary(html) ->
        case Regex.run(~r/<title>[^<]*\bv([\d]+\.[\d]+\.[\d]+[^<]*?)\s*[—–-]/, html) do
          [_, version] -> {:ok, String.trim(version)}
          _ -> {:error, :version_not_detected}
        end

      _ ->
        {:error, :fetch_failed}
    end
  end

  defp resolve_package(package, "latest") do
    url = "https://hex.pm/api/packages/#{package}"

    case Req.get(url, headers: [{"user-agent", "stdio_mcp/1.0"}]) do
      {:ok, %{status: 200, body: body}} ->
        ver = get_in(body, ["releases", Access.at(0), "version"]) || "latest"
        docs_url = get_in(body, ["meta", "links", "Docs"]) || get_in(body, ["docs_html_url"])
        {:ok, package, ver, docs_url}

      _ ->
        {:ok, package, "latest", nil}
    end
  end

  defp resolve_package(package, version), do: {:ok, package, version, nil}

  defp fetch_search_data(package, version) do
    pkg_dashed = String.replace(package, "_", "-")

    primary_urls = [
      "https://#{pkg_dashed}.hexdocs.pm/#{version}/search_data.js",
      "https://#{package}.hexdocs.pm/#{version}/search_data.js",
      "https://hexdocs.pm/#{package}/#{version}/search_data.js"
    ]

    case Enum.find_value(primary_urls, &try_fetch_js/1) do
      {:ok, data} ->
        {:ok, data}

      _ ->
        fetch_search_data_fallback(package, version)
    end
  end

  defp try_fetch_js(url) do
    case Req.get(url, headers: [{"user-agent", "stdio_mcp/1.0"}], redirect: :follow) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case parse_search_data_js(body) do
          {:ok, data} -> {:ok, data}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp fetch_search_data_fallback(package, version) do
    pkg_dashed = String.replace(package, "_", "-")
    mod_name = package |> String.split("_") |> Enum.map_join(&String.capitalize/1)

    urls = [
      "https://#{pkg_dashed}.hexdocs.pm/#{version}/api-reference.html",
      "https://#{pkg_dashed}.hexdocs.pm/api-reference.html",
      "https://#{pkg_dashed}.hexdocs.pm/#{mod_name}.html",
      "https://#{package}.hexdocs.pm/#{version}/api-reference.html",
      "https://#{package}.hexdocs.pm/api-reference.html",
      "https://#{package}.hexdocs.pm/#{mod_name}.html",
      "https://hexdocs.pm/#{package}/#{version}/api-reference.html",
      "https://hexdocs.pm/#{package}/#{version}/#{mod_name}.html"
    ]

    Enum.find_value(urls, {:error, :search_data_not_found}, fn index_url ->
      with {:ok, %{status: 200, body: html}} when is_binary(html) <-
             Req.get(index_url, headers: [{"user-agent", "stdio_mcp/1.0"}], redirect: :follow),
           [_, search_file] <-
             Regex.run(~r/src="([^"]*(?:search_data|sidebar_items)-[^"]+\.js)"/, html),
           file_url <- build_full_url(index_url, search_file),
           {:ok, %{status: 200, body: js_body}} <- Req.get(file_url, redirect: :follow),
           {:ok, data} <- parse_search_data_js(js_body) do
        {:ok, data}
      else
        _ -> nil
      end
    end)
  end

  defp build_full_url(base, relative) do
    if String.starts_with?(relative, "http") do
      relative
    else
      URI.merge(base, relative) |> to_string()
    end
  end

  def parse_search_data_js(js_content) do
    cond do
      String.contains?(js_content, "sidebarNodes=") ->
        parse_sidebar_nodes_js(js_content)

      String.contains?(js_content, "searchData =") ->
        json_str =
          js_content
          |> String.split("searchData =", parts: 2)
          |> Enum.at(1)
          |> String.trim()
          |> String.trim_trailing(";")

        decode_json_items(json_str)

      String.contains?(js_content, "searchNodes =") ->
        nodes =
          js_content
          |> String.split("searchNodes =", parts: 2)
          |> Enum.at(1)
          |> String.trim()
          |> String.trim_trailing(";")

        decode_json_items("{\"items\": #{nodes}}")

      true ->
        decode_json_items(js_content)
    end
  end

  defp decode_json_items(json_str) do
    case Jason.decode(json_str) do
      {:ok, data} -> {:ok, data}
      {:error, err} -> {:error, {:invalid_json, err}}
    end
  end

  defp parse_sidebar_nodes_js(js_content) do
    json_str =
      js_content
      |> String.split("sidebarNodes=", parts: 2)
      |> Enum.at(1)
      |> String.trim()
      |> String.replace(~r/;*\s*$/, "")

    case Jason.decode(json_str) do
      {:ok, map} ->
        items = extract_items_from_sidebar_nodes(map)
        {:ok, %{"items" => items}}

      {:error, err} ->
        Logger.error("[IngestionWorker] sidebarNodes JSON decode error: #{inspect(err)}")
        {:error, {:invalid_json, err}}
    end
  end

  defp extract_items_from_sidebar_nodes(map) when is_map(map) do
    modules = Map.get(map, "modules", [])
    extras = Map.get(map, "extras", [])

    module_items = Enum.flat_map(modules, &extract_module_items/1)

    extra_items =
      Enum.map(extras, fn extra ->
        id = Map.get(extra, "id", "")
        title = Map.get(extra, "title", id)

        %{
          "ref" => "#{id}.html",
          "title" => title,
          "doc" => title,
          "type" => "guide"
        }
      end)

    module_items ++ extra_items
  end

  defp extract_module_items(mod) do
    mod_id = Map.get(mod, "id", "")
    mod_title = Map.get(mod, "title", mod_id)

    mod_item = %{
      "ref" => "#{mod_id}.html",
      "title" => mod_title,
      "doc" => mod_title,
      "type" => "module"
    }

    func_items =
      mod
      |> Map.get("nodeGroups", [])
      |> Enum.flat_map(&extract_node_group_items(mod_id, mod_title, &1))

    [mod_item | func_items]
  end

  defp extract_node_group_items(mod_id, mod_title, group) do
    key = Map.get(group, "key", "function")

    group
    |> Map.get("nodes", [])
    |> Enum.map(fn node ->
      node_id = Map.get(node, "id", "")
      anchor = Map.get(node, "anchor", node_id)

      %{
        "ref" => "#{mod_id}.html##{anchor}",
        "title" => "#{mod_title}.#{node_id}",
        "doc" => "#{mod_title}.#{node_id}",
        "type" => key
      }
    end)
  end

  defp build_base_url(nil, package, version) do
    "https://hexdocs.pm/#{package}/#{version}"
  end

  defp build_base_url(docs_url, _package, _version) do
    String.trim_trailing(docs_url, "/")
  end

  def build_doc_items(package, version, item) when is_map(item) do
    build_doc_items(package, version, "https://hexdocs.pm/#{package}/#{version}", item)
  end

  def build_doc_items(_package, _version, _item), do: []

  def build_doc_items(_package, _version, base_url, item) when is_map(item) do
    ref = Map.get(item, "ref", "")
    title = Map.get(item, "title", Map.get(item, "name", ""))
    doc_text = Map.get(item, "doc", Map.get(item, "doc_html", ""))
    type = to_string(Map.get(item, "type", "doc"))
    hexdocs_url = "#{base_url}/#{ref}"

    content = resolve_content(doc_text, title, hexdocs_url)

    if content != "" || title != "" do
      chunks = chunk_content(content)
      multi_part? = match?([_, _ | _], chunks)

      item_meta = %{ref: ref, title: title, type: type, url: hexdocs_url}

      Enum.with_index(chunks, fn chunk, idx ->
        build_chunk_item(chunk, idx, multi_part?, item_meta)
      end)
    else
      []
    end
  end

  def build_doc_items(_package, _version, _base_url, _item), do: []

  # A doc entry may be split into several chunks; only then does a chunk get a
  # "Part N" suffix, so a single-chunk entry keeps its original signature.
  defp build_chunk_item(chunk, idx, multi_part?, meta) do
    suffix = if multi_part?, do: " - Part #{idx + 1}", else: ""

    %{
      doc_type: meta.type,
      module: extract_module(meta.ref, meta.title),
      function: extract_function(meta.title, meta.type),
      signature: "#{meta.title}#{suffix}",
      content: chunk,
      code_snippet: extract_first_code_snippet(chunk),
      hexdocs_url: meta.url,
      embedding: nil
    }
  end

  # searchData/searchNodes entries sometimes carry real documentation and
  # sometimes only echo the title; in the latter case the page itself is the
  # only source of content.
  defp resolve_content(doc_text, title, hexdocs_url) do
    if real_content?(doc_text, title) do
      doc_text
    else
      case fetch_doc_content(hexdocs_url) do
        "" -> doc_text
        fetched -> fetched
      end
    end
  end

  defp real_content?(doc_text, title) do
    doc_text != "" and doc_text != title and String.length(doc_text) > String.length(title)
  end

  defp chunk_content(text) do
    case TextChunker.split(text, format: :markdown, target_chunk_size: 400) do
      {:error, _} -> [text]
      chunks when is_list(chunks) -> Enum.map(chunks, & &1.text)
    end
  end

  defp fetch_doc_content(url) do
    {page_url, anchor} = split_url_anchor(url)

    case cached_fetch_page(page_url) do
      "" -> ""
      html -> extract_for_anchor(html, anchor)
    end
  end

  # With an anchor, prefer just that section of the page; fall back to the whole
  # page when the anchor yields nothing.
  defp extract_for_anchor(html, nil), do: extract_text_from_html(html)

  defp extract_for_anchor(html, anchor) do
    case extract_section_by_anchor(html, anchor) do
      "" -> extract_text_from_html(html)
      section -> section
    end
  end

  defp split_url_anchor(url) do
    case String.split(url, "#", parts: 2) do
      [page, anchor] -> {page, anchor}
      [page] -> {page, nil}
    end
  end

  defp cached_fetch_page(page_url) do
    cache_key = {:html_cache, page_url}

    case Process.get(cache_key) do
      nil ->
        html =
          case Req.get(page_url,
                 headers: [{"user-agent", "stdio_mcp/1.0"}],
                 redirect: :follow
               ) do
            {:ok, %{status: 200, body: body}} when is_binary(body) -> body
            _ -> ""
          end

        Process.put(cache_key, html)
        html

      cached ->
        cached
    end
  end

  defp extract_section_by_anchor(html, anchor) do
    # Match <section id="anchor">...</section>
    pattern = ~r/<section[^>]*id="#{Regex.escape(anchor)}"[^>]*>(.*?)<\/section>/si

    case Regex.run(pattern, html) do
      [_, section_html] -> extract_text_from_html_fragment(section_html)
      _ -> ""
    end
  end

  defp extract_text_from_html(html) do
    content_html =
      case Regex.run(
             ~r/<(?:div|main)[^>]*id=["'](?:content|main)["'][^>]*>(.*)<\/(?:div|main)>/s,
             html
           ) do
        [_, inner] -> inner
        _ -> html
      end

    extract_text_from_html_fragment(content_html)
  end

  defp extract_text_from_html_fragment(html) do
    html
    |> String.replace(~r/<script.*?>.*?<\/script>/is, "")
    |> String.replace(~r/<style.*?>.*?<\/style>/is, "")
    |> String.replace(~r/<(p|h[1-6]|li|br|div|tr|section|article)[^>]*>/i, "\n")
    |> String.replace(~r/<[^>]+>/, "")
    |> decode_html_entities()
    |> String.replace(~r/\n\s*\n/, "\n\n")
    |> String.trim()
  end

  defp decode_html_entities(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
  end

  defp extract_module(ref, _title) do
    ref
    |> String.split("#")
    |> List.first()
    |> String.replace(~r/\.html$/, "")
  end

  defp extract_function(title, type) when type in ["function", "macro"] do
    if String.contains?(title, "/") do
      title
    else
      nil
    end
  end

  defp extract_function(_title, _type), do: nil

  defp extract_first_code_snippet(text) do
    case Regex.run(~r/```(?:elixir)?\n(.*?)```/s, text) do
      [_, code] -> String.trim(code)
      _ -> nil
    end
  end

  defp attach_embeddings_batch(docs) do
    docs
    |> Enum.chunk_every(50)
    |> Enum.flat_map(&embed_batch/1)
  end

  defp embed_batch(batch, attempts \\ 1) do
    texts = Enum.map(batch, &doc_to_embed_text/1)

    case Client.embed_batch(texts) do
      {:ok, vectors} when is_list(vectors) and length(vectors) == length(batch) ->
        Enum.zip_with(batch, vectors, fn doc, vec ->
          Map.put(doc, :embedding, vec)
        end)

      {:error, {429, _}} when attempts <= 3 ->
        Logger.warning("[IngestionWorker] AI rate limit 429, backing off #{attempts}s...")
        Process.sleep(attempts * 1000)
        embed_batch(batch, attempts + 1)

      err ->
        Logger.error("[IngestionWorker] Client.embed_batch error: #{inspect(err)}")
        Enum.map(batch, &Map.put(&1, :embedding, nil))
    end
  end

  defp doc_to_embed_text(doc) do
    text = String.trim("#{doc.signature || ""}\n#{doc.content || ""}")
    if text == "", do: doc.module || "doc", else: text
  end

  defp save_docs(docs, package, version) do
    Repo.transaction(fn ->
      Repo.delete_all(
        from(d in PackageDoc, where: d.package == ^package and d.version == ^version)
      )

      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      entries =
        Enum.map(docs, fn doc ->
          %{
            package: package,
            version: version,
            doc_type: to_string(doc.doc_type),
            module: doc.module,
            function: doc.function,
            signature: doc.signature,
            content: doc.content,
            code_snippet: doc.code_snippet,
            hexdocs_url: doc.hexdocs_url,
            embedding: if(doc.embedding, do: Jason.encode!(doc.embedding), else: nil),
            inserted_at: now,
            updated_at: now
          }
        end)

      entries
      |> Enum.chunk_every(100)
      |> Enum.each(&Repo.insert_all(PackageDoc, &1))
    end)

    {:ok, length(docs)}
  end
end

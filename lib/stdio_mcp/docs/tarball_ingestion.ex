defmodule StdioMcp.Docs.TarballIngestion do
  @moduledoc """
  Ingests a package's documentation from its Hex docs tarball.

  Docs were previously reconstructed by scraping hexdocs.pm: probing for
  `search_data.js` (which 404s for every package tested), falling back to
  scraping HTML for a `sidebar_items-*.js` navigation index that carries no
  documentation text, then fetching one HTML page per item — 761 requests for
  `anubis_mcp` alone. All of that existed to reconstruct something Hex already
  publishes.

  The tarball at `https://repo.hex.pm/docs/{package}-{version}.tar.gz` contains:

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
  alias StdioMcp.Docs.EmbeddingConfig
  alias StdioMcp.Docs.IngestionJob
  alias StdioMcp.Docs.SectionChunker
  alias StdioMcp.PackageDoc
  alias StdioMcp.Repo

  import Ecto.Query
  require Logger

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

  # Optional pacing between embedding requests, for providers that rate-limit on
  # requests-per-second. Default 0 — a capable endpoint pays nothing. Set
  # EMBED_PAUSE_MS to slow the stream down without touching concurrency.
  @default_embed_pause_ms 0

  defp embed_pause_ms do
    Application.get_env(:stdio_mcp, :embed_pause_ms, @default_embed_pause_ms)
  end

  @embed_batch_timeout 180_000
  @embed_max_attempts 5
  @embed_backoff_ms 1_000
  @embed_backoff_max_ms 30_000

  @doc """
  Ingests `package` at a concrete `version`.

  Resolution happens in `StdioMcp.Docs.Search`, which needs the Hex metadata for
  its own decisions anyway — fetching it here as well would mean two requests for
  one answer. `docs_url` is Hex's own `docs_html_url` when the caller has it;
  without it the URL is constructed.

  Returns `{:ok, rows_written, version}`.
  """
  @spec ingest(String.t(), String.t(), String.t() | nil) ::
          {:ok, non_neg_integer(), String.t()} | {:error, term()}
  def ingest(package, version, docs_url \\ nil)
      when is_binary(package) and is_binary(version) do
    base_url = docs_base_url(package, version, docs_url)
    :ok = IngestionJob.stage(:downloading)

    # Checked before the download, not after: a mixed-model index cannot be
    # repaired by searching harder, and refusing costs one DB read where
    # proceeding costs a tarball plus a full re-embed to produce vectors that are
    # not comparable to anything already stored.
    with :ok <- EmbeddingConfig.allow_ingest(Client.embed_model()),
         {:ok, tarball} <- download(package, version),
         {:ok, %{} = files} <- extract(tarball),
         {:ok, items} <- read_index(files),
         docs =
           items
           |> Enum.flat_map(&build_docs(&1, files, base_url))
           |> Enum.map(&Map.put(&1, :package, package)),

         # Embedding failure aborts the ingest instead of saving. Persisting rows
         # with nil embeddings writes an index that looks complete, passes every
         # count check, and is invisible to vector search — a silent, permanent
         # quality loss that only a re-ingest can undo.
         {:ok, embedded} <- attach_embeddings(docs) do
      IngestionJob.stage(:saving)

      case save(embedded, package, version) do
        {:ok, count} -> {:ok, count, version}
        error -> error
      end

      # else
      # {:error, reason} -> Logger.warning("[Embedding]: #{reason}")
    end
  end

  # HexDocs moved packages to per-package subdomains, and the old
  # `hexdocs.pm/{package}/{version}` path now answers 301 pointing at
  # `{package}.hexdocs.pm/{version}`. These URLs are stored on every row and
  # handed to callers as the canonical link, so emitting the legacy form leaves
  # the whole index depending on a redirect that Hex may eventually retire.
  #
  # The underscore→hyphen conversion is not cosmetic: hostnames may only contain
  # letters, digits and hyphens (RFC 1123), so `ecto_sql.hexdocs.pm` is not a
  # legal name and answers 421 Misdirected Request. Every underscore package —
  # ecto_sql, gen_magic, anubis_mcp, text_chunker — depends on this line.
  #
  # Note the tarball itself is *not* affected: it is fetched from
  # `repo.hex.pm/docs/{package}-{version}.tar.gz`, a path where the underscore
  # must be preserved.
  # Hex's own `docs_html_url` is preferred when we have it: it is authoritative,
  # already does the same hyphen conversion ("https://ecto-sql.hexdocs.pm/"), and
  # tracks any future scheme change for free. It is unversioned, so the version
  # is appended.
  defp docs_base_url(_package, version, docs_url) when is_binary(docs_url) do
    "#{String.trim_trailing(docs_url, "/")}/#{version}"
  end

  defp docs_base_url(package, version, _docs_url) do
    "https://#{String.replace(package, "_", "-")}.hexdocs.pm/#{version}"
  end

  # -- Acquisition ------------------------------------------------------------

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
      chunks = SectionChunker.chunk(content)
      multi? = match?([_, _ | _], chunks)

      Enum.with_index(chunks, fn chunk, idx ->
        %{
          doc_type: type,
          module: module,
          function: function,
          signature: signature(title, chunk.path, idx, multi?),
          content: chunk.text,
          code_snippet: first_code_block(chunk.text),
          hexdocs_url: url
        }
      end)
    end
  end

  # `signature` is displayed *and* fed to the embedding via `embed_text/1`, so
  # naming the chunk is worth more than numbering it: "connect/1 — Allowed
  # options" tells both a reader and the embedding model what the fragment is,
  # where "connect/1 - Part 2" told neither. The ordinal stays only as the
  # fallback for a document with no headings to borrow a name from, where it is
  # at least honest about being one piece of several.
  defp signature(title, _path, _idx, false), do: title

  defp signature(title, [], idx, true), do: "#{title} - Part #{idx + 1}"

  defp signature(title, path, _idx, true), do: "#{title} — #{Enum.join(path, " › ")}"

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

    # Markdown is preferred, but an anchor it cannot locate now yields "" rather
    # than the whole file, so the HTML page gets a chance at that one section
    # instead of the item inheriting the entire module document.
    with md when is_binary(md) <- Map.get(files, base <> ".md"),
         section when section != "" <- markdown_section(md, anchor) do
      section
    else
      _no_markdown_section ->
        case Map.get(files, page) do
          html when is_binary(html) -> html_section(html, anchor)
          _missing -> ""
        end
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

  defp first_code_block(text) do
    case Regex.run(~r/```[a-z]*\n(.*?)```/s, text) do
      [_, code] -> String.trim(code)
      _ -> nil
    end
  end

  defp markdown_section(md, nil), do: md

  # A markdown page carries two kinds of heading and they need different matching:
  #
  #   prose sections   "## Provided options"  ->  anchor "module-provided-options"
  #   member headings  "# `bind_value`"       ->  anchor "t:bind_value/0"
  #
  # Slugifying works for the first and fails for the second, because `slug/1`
  # strips underscores (markdown `_emphasis_`), turning `bind_value` into
  # "bindvalue". Members are identifiers, not prose, so they are compared
  # verbatim after removing backticks, while the anchor sheds its `t:`/`c:`
  # prefix and `/arity` suffix.
  defp markdown_section(md, anchor) do
    lines = String.split(md, "\n")
    targets = anchor_targets(anchor)

    start =
      Enum.find_index(lines, fn line ->
        case Regex.run(~r/^\#{1,6}\s+(.*)$/u, line) do
          [_, heading] -> slug(heading) in targets or member_name(heading) in targets
          _ -> false
        end
      end)

    case start do
      # Returning the whole document here is what produced the duplication this
      # replaced: every one of a module's members resolved to the same 14k file,
      # which then chunked into a dozen parts and was stored once per member —
      # 746 exqlite rows holding 216 distinct texts, one blob repeated 36 times.
      # Returning "" lets `page_content/2` fall through to the HTML page instead.
      nil ->
        ""

      start ->
        rest = Enum.drop(lines, start + 1)
        len = Enum.find_index(rest, &Regex.match?(~r/^\#{1,6}\s+/u, &1)) || length(rest)
        [Enum.at(lines, start) | Enum.take(rest, len)] |> Enum.join("\n") |> String.trim()
    end
  end

  defp anchor_targets(anchor) do
    base = String.replace_prefix(anchor, "module-", "")

    member =
      base
      |> String.replace(~r/^[tc]:/, "")
      |> String.replace(~r|/\d+$|, "")
      |> String.downcase()

    [anchor, base, member]
  end

  defp member_name(heading) do
    heading |> String.replace("`", "") |> String.trim() |> String.downcase()
  end

  defp slug(heading) do
    heading
    |> String.replace(~r/`|\*|_/u, "")
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/u, "")
    |> String.replace(~r/\s+/u, "-")
  end

  @heading_tags ~w(h1 h2 h3 h4 h5 h6)

  # ExDoc wraps the real page body in `<div id="content">` — true for both modern
  # ExDoc and 0.23-era output — and keeps the footer, sidebar and the keyboard/
  # theme modals *outside* it. Selecting that node is what excludes the chrome.
  #
  # The regex this replaces could not: `id="content">(.*)</div>` with the `s`
  # flag is greedy, so it ran to the *last* `</div>` on the page and swallowed
  # the very footer and modals it was meant to cut, which is how "Toggle night
  # mode" ended up indexed as documentation.
  defp html_section(html, anchor) do
    html
    |> LazyHTML.from_document()
    |> content_root()
    |> LazyHTML.to_tree()
    |> narrow_to_anchor(anchor)
    |> node_text()
    |> normalize_whitespace()
  end

  defp content_root(doc) do
    Enum.find_value(["#content", "main"], doc, fn selector ->
      case LazyHTML.query(doc, selector) do
        nodes -> if Enum.empty?(nodes), do: nil, else: nodes
      end
    end)
  end

  defp narrow_to_anchor(tree, nil), do: tree

  # Two shapes carry an anchor: `<section id="foo/2">` for function details, and
  # `<h2 id="the-server-module">` for guide and moduledoc sections. Without the
  # second, guide anchors fell through to the whole page.
  #
  # Matching the id as a plain string rather than through a CSS selector is
  # deliberate: ExDoc anchors are things like `perform/2` and `c:execute/2`, and
  # `/` and `:` are not legal in an unescaped id selector.
  # An anchor we cannot locate yields nothing rather than the whole page. The
  # markdown path had the same shape and it was expensive: every member of a
  # module resolved to the same document, which then chunked and was stored once
  # per member — 746 exqlite rows holding 216 distinct texts. It looks like
  # success (content returned, row count up) and only a distinct-value count
  # reveals it.
  #
  # `build_docs/3` keeps a row as long as the title is non-empty, so the item
  # degrades to a title-only entry: it still records that the member exists and
  # is still findable by name, without copying a page across its siblings.
  defp narrow_to_anchor(tree, anchor) do
    case find_by_id(tree, anchor) do
      nil -> []
      {tag, _attrs, _children} when tag in @heading_tags -> heading_slice(tree, anchor) || []
      node -> [node]
    end
  end

  # ExDoc 0.23 marks a function detail with an *empty* `<span id="perform/2">`
  # and keeps the documentation in the enclosing `<section>`; modern ExDoc puts
  # the id on the section itself. Returning the element that literally carries
  # the id therefore yields "" for older packages, so a match with no text of its
  # own resolves to the nearest ancestor that has some.
  #
  # The regex this replaces looked only for `<section id=...>`, found nothing on
  # those pages, and fell through to the entire page body — every function anchor
  # on an old package indexed the whole module page.
  defp find_by_id(nodes, id) when is_list(nodes), do: Enum.find_value(nodes, &find_by_id(&1, id))

  defp find_by_id({_tag, attrs, children} = node, id) do
    if Enum.any?(attrs, fn {k, v} -> k == "id" and v == id end) do
      node
    else
      case find_by_id(children, id) do
        nil -> nil
        found -> if blank?(found), do: node, else: found
      end
    end
  end

  defp find_by_id(_other, _id), do: nil

  defp blank?(node), do: node |> node_text() |> String.trim() == ""

  # A section runs until the next heading of the same or higher rank: an h2 must
  # swallow its h3 subsections, not stop at the first one. Stopping at any
  # heading left changelog entries as a bare date line.
  defp heading_slice(tree, anchor) do
    case locate_heading(tree, anchor) do
      nil ->
        nil

      {siblings, idx, level} ->
        [heading | rest] = Enum.drop(siblings, idx)

        following =
          Enum.take_while(rest, fn
            {tag, _attrs, _children} when tag in @heading_tags -> heading_level(tag) > level
            _other -> true
          end)

        [heading | following]
    end
  end

  # The heading's own sibling list is what gets sliced, so the search returns it
  # alongside the position — a heading nested in a <section> wrapper must slice
  # within that wrapper, not at the top level.
  defp locate_heading(nodes, anchor) when is_list(nodes) do
    case Enum.find_index(nodes, &heading_with_id?(&1, anchor)) do
      nil ->
        Enum.find_value(nodes, fn
          {_tag, _attrs, children} -> locate_heading(children, anchor)
          _other -> nil
        end)

      idx ->
        {tag, _attrs, _children} = Enum.at(nodes, idx)
        {nodes, idx, heading_level(tag)}
    end
  end

  defp locate_heading(_other, _anchor), do: nil

  defp heading_with_id?({tag, attrs, _children}, anchor) when tag in @heading_tags do
    Enum.any?(attrs, fn {k, v} -> k == "id" and v == anchor end)
  end

  defp heading_with_id?(_node, _anchor), do: false

  defp heading_level("h" <> level), do: String.to_integer(level)

  # Text of these is markup machinery, not prose. The old tag-stripping regex
  # removed the elements; walking a tree means skipping them explicitly, or
  # `.x{color:red}` gets indexed and embedded as documentation.
  # `footer` is here because ExDoc 0.23-era pages put the footer *inside*
  # `#content` — measured: every chrome string ("Toggle night mode", "Display
  # keyboard shortcuts", "Built using ExDoc", …) lives in that one element.
  # Modern ExDoc keeps it outside `#content`, so selecting the container is
  # enough there; on older packages it is not, and those are exactly the ones
  # this pipeline exists to handle.
  @non_content_tags ~w(script style template noscript footer)

  # Only block-level elements produce a line break. Everything else concatenates,
  # which is the entire reason for parsing instead of pattern-replacing: the old
  # `~r/<[^>]+>/ -> " "` turned every tag boundary into a space, and ExDoc wraps
  # each highlighted token in its own <span>, so `GenMagic.Server.perform(path)`
  # came out as `GenMagic.Server . perform ( path )` — unsearchable as a token and
  # useless as a code sample.
  # `footer`, `pre` and the table row/cell tags are deliberately absent — each has
  # its own clause. Listing a tag in both would work only by clause order, which
  # is too subtle to rely on.
  @block_tags ~w(address article aside blockquote br dd details div dl dt
                 fieldset figcaption figure form h1 h2 h3 h4 h5 h6 header
                 hr li main nav ol p section summary table tbody thead ul)

  # ExDoc decorates headings and detail blocks with anchor links whose text is
  # navigation, not documentation: "View Source", "Link to this function", "Link
  # to this section". Measured at 49% of stored rows and byte-identical across
  # every package, so they pull every function row toward every other one in
  # vector space while consuming embedding tokens.
  #
  # The class names differ across ExDoc generations and the list must cover both,
  # because old packages are exactly the ones this HTML path exists for while new
  # ones still reach it whenever a page ships no markdown:
  #
  #   icon-action   "View Source"                  modern ExDoc
  #   view-source   "View Source"                  0.23-era
  #   detail-link   "Link to this function/macro"  both
  #   hover-link    "Link to this section"         0.23-era
  #
  # Deriving the list from a single page is how `icon-action` was missed, leaving
  # 18 of 69 sqlite_vec rows carrying "View Source" after a refresh that was
  # supposed to remove it.
  @chrome_classes ~w(detail-link view-source hover-link icon-action)

  # The second argument tracks whether the walk is inside a `<pre>`, because
  # whitespace is only significant there. Outside it, HTML treats any run of
  # whitespace as a single space, so collapsing per text node is simply correct —
  # and doing it here rather than in one final pass is what lets code keep its
  # indentation.
  defp node_text(nodes), do: node_text(nodes, false)

  defp node_text(nodes, pre?) when is_list(nodes),
    do: Enum.map_join(nodes, &node_text(&1, pre?))

  defp node_text(text, true) when is_binary(text), do: denbsp(text)
  defp node_text(text, false) when is_binary(text), do: text |> denbsp() |> collapse()
  defp node_text({:comment, _content}, _pre?), do: ""
  defp node_text({tag, _attrs, _children}, _pre?) when tag in @non_content_tags, do: " "

  # Emitting a fenced block is what makes `first_code_block/1` work on the HTML
  # path at all: it looks for ``` fences, HTML-derived content had none, so
  # `code_snippet` was silently nil for every older package and
  # `include_examples_only` returned nothing for them. It also gives TextChunker
  # (running in `:markdown` format) a real code block to avoid splitting.
  defp node_text({"pre", _attrs, children}, _pre?) do
    "\n```\n" <> String.trim(node_text(children, true)) <> "\n```\n"
  end

  # A table rendered as newline-separated cells loses the column relationship:
  # ":startup_timeout 1000 Number of milliseconds..." reads as one run-on, and a
  # description containing a number becomes ambiguous. Pipes keep the pairing.
  defp node_text({"tr", _attrs, children}, pre?) do
    case Enum.filter(children, &table_cell?/1) do
      [] ->
        "\n" <> node_text(children, pre?) <> "\n"

      cells ->
        row = "\n| " <> Enum.map_join(cells, " | ", &cell_text(&1, pre?)) <> " |"

        if header_row?(cells),
          do: row <> "\n|" <> String.duplicate(" --- |", length(cells)),
          else: row
    end
  end

  defp node_text({tag, attrs, children}, pre?) do
    cond do
      chrome?(attrs) -> ""
      tag in @block_tags -> "\n" <> node_text(children, pre?) <> "\n"
      true -> node_text(children, pre?)
    end
  end

  defp table_cell?({tag, _attrs, _children}) when tag in ~w(td th), do: true
  defp table_cell?(_node), do: false

  defp header_row?(cells), do: Enum.all?(cells, fn {tag, _, _} -> tag == "th" end)

  # A cell's own line breaks would end the row early, and a literal pipe would
  # invent a column.
  defp cell_text(cell, pre?) do
    cell
    |> node_text(pre?)
    |> String.replace(~r/\s+/u, " ")
    |> String.replace("|", "\\|")
    |> String.trim()
  end

  defp chrome?(attrs) do
    case List.keyfind(attrs, "class", 0) do
      {"class", classes} -> classes |> String.split() |> Enum.any?(&(&1 in @chrome_classes))
      _no_class -> false
    end
  end

  # The parser decodes entities itself, so the hand-rolled table is gone — but
  # `&nbsp;` decodes to a literal U+00A0, which would otherwise reach the index
  # as a non-breaking space and break matching on any phrase containing it.
  defp denbsp(text), do: String.replace(text, "\u00A0", " ")

  defp collapse(text), do: String.replace(text, ~r/\s+/u, " ")

  # Only blank-line squashing stays global. Space collapsing moved into the walk
  # so that it cannot reach inside a fenced code block and flatten its
  # indentation \u2014 which is the whole point of emitting fences.
  defp normalize_whitespace(text) do
    text
    |> String.replace(~r/[ \t]+\n/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
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
      {:ok, acc, _done} ->
        embedded = acc |> Enum.reverse() |> Enum.concat()
        record_embedding_config(embedded)
        {:ok, embedded}

      {:error, reason} ->
        {:error, {:embedding_failed, reason}}
    end
  end

  # Recorded from the vectors themselves rather than from configuration: the
  # dimension is a property of what the provider actually returned, and taking it
  # from the response is what makes the record evidence instead of a restatement
  # of the env var. Written after embedding succeeds, so a failed ingest leaves
  # the previous record — and the previous rows — intact.
  defp record_embedding_config([%{embedding: [_ | _] = vector} | _rest]) do
    model = Client.embed_model()
    dims = length(vector)

    Logger.info("[TarballIngestion] embedded with #{model} (#{dims} dims)")

    case EmbeddingConfig.record(model, dims) do
      :ok ->
        :ok

      {:error, reason} ->
        # The vectors are still good; only the record failed. Searches fall back
        # to treating the index as unverified rather than refusing it.
        Logger.warning("[TarballIngestion] could not record embedding config: #{inspect(reason)}")
        :ok
    end
  end

  defp record_embedding_config(_docs), do: :ok

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
          pause()
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

      # The provider caps tokens per *request*, not inputs, so a batch that is
      # fine by count can still be rejected: exqlite's 141 docs are ~15k tokens
      # in one request. Bisecting asks the API where the line is instead of
      # guessing at its tokenizer, and converges in a few halvings.
      {:error, {400, detail}} ->
        split_batch(batch, detail, attempt)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp split_batch(batch, detail, attempt) when length(batch) > 1 do
    if token_overflow?(detail) do
      {left, right} = Enum.split(batch, div(length(batch), 2))

      Logger.warning(
        "[TarballIngestion] batch of #{length(batch)} over the token limit, " <>
          "splitting into #{length(left)} + #{length(right)}"
      )

      with {:ok, embedded_left} <- embed_batch(left, attempt),
           {:ok, embedded_right} <- embed_batch(right, attempt) do
        {:ok, embedded_left ++ embedded_right}
      end
    else
      {:error, {400, detail}}
    end
  end

  # Down to a single input and still refused: that one document cannot be
  # embedded at all, and saying so beats halving forever.
  defp split_batch(batch, detail, _attempt) do
    if token_overflow?(detail),
      do: {:error, {:doc_exceeds_token_limit, length(batch), detail}},
      else: {:error, {400, detail}}
  end

  # Matched on the provider's code first, with a message fallback so a renamed
  # code does not silently turn "split me" back into a hard failure. Other 400s
  # (malformed input, bad model) must not be bisected — halving would just fail
  # twice as often.
  defp token_overflow?(%{"code" => "3210"}), do: true

  defp token_overflow?(%{"message" => message}) when is_binary(message) do
    String.contains?(String.downcase(message), "too many tokens")
  end

  defp token_overflow?(_detail), do: false

  defp pause do
    case embed_pause_ms() do
      ms when is_integer(ms) and ms > 0 -> Process.sleep(ms)
      _none -> :ok
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

  # The package name leads because every search is scoped to one package, and a
  # chunk that never says which library it belongs to sits in the same region of
  # vector space as the identically-worded chunk from another. `signature` now
  # carries the heading trail (see `signature/4`), which is what replaced the
  # 100-byte overlap as the way a fragment states its context.
  #
  # `uniq` matters for stub rows. A moduledoc has `module` and `signature` both
  # set to the module name, so the identifier was embedded twice — and for the
  # 32% of rows carrying under 60 bytes of content there is nothing else in the
  # vector to balance it:
  #
  #   "boruta Boruta.Oauth.ClientCredentialsRequest \
  #    Boruta.Oauth.ClientCredentialsRequest Client credentials request"
  defp embed_text(doc) do
    [doc.package, doc.module, doc.function, doc.signature, doc.content]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  # Prunes by package, not by package *and* version: one version per package is
  # the invariant. Deleting only the matching version left the previous one
  # behind, so a package ingested at two versions answered unpinned searches with
  # both interleaved and nothing said so. The FTS index follows automatically —
  # `package_docs_ad` fires on delete, `package_docs_ai` on insert.
  defp save(docs, package, version) do
    Repo.transaction(fn ->
      Repo.delete_all(from(d in PackageDoc, where: d.package == ^package))

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

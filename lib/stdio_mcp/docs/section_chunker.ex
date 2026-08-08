defmodule StdioMcp.Docs.SectionChunker do
  @moduledoc """
  Splits documentation markdown at structural boundaries instead of at byte
  offsets.

  ## What this replaces

  `TextChunker`'s recursive splitter walks a separator list and descends to the
  next separator whenever a piece still exceeds `chunk_size`. With
  `chunk_size: 1200` no code block and few option lists fit, so it fell through
  to `"\\n\\n"`, then `"\\n"`, and cut wherever the byte count ran out. Measured on
  `Exqlite.Connection.connect/1` — a 3.5KB flat list of connection options — that
  put the split in the middle of the list, and `chunk_overlap: 100` then
  duplicated the straddling line into both halves:

      * `:temp_store` - … It is
        recommended that you use `:memory` for storage.
                                                          <- end of part 1
        recommended that you use `:memory` for storage.    <- start of part 2
      * `:synchronous` - …

  Two costs. The duplicated fragment is indexed and embedded twice, and neither
  half is a coherent unit: half the options are in one vector, half in another,
  and a query about `:journal_mode` competes against a chunk that holds the
  *other* options with equal claim to the same heading.

  ## The boundaries, in priority order

  1. **Headings** (level 1-3) — a section, with its own heading kept in the body
     so the keyword arm can still match on it.
  2. **Blocks** — paragraphs, code blocks, lists, tables, grouped greedily up to
     the byte budget. A code block is never split by this step.
  3. **List items** — the unit that matters for an options list, which is the
     shape most oversized `@doc` bodies actually have.
  4. **`TextChunker`** — kept as the floor for the one case nothing structural
     helps with: a single block, usually a code sample, larger than the budget.

  Nothing overlaps. Overlap exists to stop a byte-offset cut from severing a
  thought; a cut that lands on a structural boundary has nothing to repair, and
  the duplicated text costs an embedding and pollutes the keyword index.

  ## Breadcrumbs instead of overlap

  Every chunk carries `path`, the heading trail above it (`["Allowed options"]`).
  The caller puts that in `signature`, which is both displayed and fed to the
  embedding — so a fragment of an options list still says what it is a fragment
  *of*, which is what the overlap was badly approximating.

  `path` says what the fragment is part of; it does not say which part. Every
  slice of one section shares a heading trail, so for the shape that most often
  needs splitting — a flat option list under a single heading — the breadcrumb is
  identical across siblings and discriminates nothing. Measured on the first
  corpus built this way, 12.4% of rows fell back to a bare `- Part N`, against
  2.1% that got a heading trail: the informative case was outnumbered six to one.

  So chunks also carry `terms`, the options they actually document, read off the
  leading inline-code span of each top-level list item:

      Exqlite.Connection.connect/1 — :journal_mode, :wal_auto_check_point
      Exqlite.Connection.connect/1 — :foreign_keys, :chunk_size

  Unlike an ordinal this is real signal on both arms: the keyword index gets the
  identifier a reader would search for, and the embedding gets a name that
  distinguishes the fragment holding the answer from its four siblings.

  ## Navigation sections are dropped

  ExDoc guides end in a `Next steps` / `Where to go next` section that is nothing
  but relative links to sibling pages:

      - [Transports](transports.md) details each transport option.
      - [Building a Server](building-a-server.md) covers the other side.

  These rank well and can never answer anything — they are made of the titles
  people search for. Five of ten FTS results and four of ten vector results for
  `"Building a Server"` against `anubis_mcp` were these. They are detected
  structurally rather than by heading text, which varies across packages: a
  section whose body is only lists, whose items mostly begin with a link to a
  relative destination, and which contains no code.
  """

  require Logger

  # ExDoc markdown is GFM. Tables in particular are not CommonMark, and without
  # this an options table parses as a paragraph of pipes — losing the column
  # relationship the HTML path goes to some trouble to preserve.
  @parse_opts [
    extension: [
      table: true,
      strikethrough: true,
      autolink: true,
      tasklist: true,
      footnotes: true
    ]
  ]

  # Headings deeper than this stay inside their parent section. An ExDoc `@doc`
  # uses h2/h3 for "Examples" and "Options"; h4+ is usually a label inside one of
  # those and splitting there produces fragments too small to stand alone.
  @section_level 3

  # The embedding model's 8k window is not the binding constraint — readability
  # in the payload is. A chunk much beyond this stops being a section and starts
  # being a page, and the whole pool of ten is returned to the caller.
  #
  # It was originally chosen against a cross-encoder reranker, whose 512-token
  # pair is roughly 2000 characters; that stage has since been removed, but the
  # size measured well and is kept.
  @default_max_bytes 1600

  # Below this a chunk is a heading and a sentence — it dilutes the index without
  # being able to answer. Merged into a neighbour under the same heading instead.
  @default_min_bytes 250

  # Enough to tell four slices of one option list apart without turning the
  # signature into a second copy of the chunk. The first items of a group are the
  # ones a reader scanning the name will match on.
  @max_terms 4

  @typedoc """
  `path` is the heading trail above the chunk, outermost first. Empty for a
  document with no headings, which is the common case for a function `@doc`.

  `terms` are the option or member names the chunk documents, in source order.
  Empty for prose. Where `path` is context, `terms` are identity — they are what
  differs between slices of one section.
  """
  @type chunk :: %{text: String.t(), path: [String.t()], terms: [String.t()]}

  @doc """
  Splits `markdown` into chunks that respect its structure.

  Returns `[%{text: _, path: _}]`. A document that already fits the budget comes
  back as a single chunk with an empty path and its text unchanged, so the common
  case costs one parse and no restructuring.
  """
  @spec chunk(String.t(), keyword()) :: [chunk()]
  def chunk(markdown, opts \\ []) when is_binary(markdown) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    min_bytes = Keyword.get(opts, :min_bytes, @default_min_bytes)

    lines = String.split(markdown, "\n")

    markdown
    |> parse()
    |> sections()
    |> Enum.reject(&navigation?/1)
    |> Enum.flat_map(&split_oversized(&1, max_bytes, lines))
    |> merge_undersized(min_bytes, max_bytes, lines)
    |> Enum.map(&render(&1, lines))
    |> Enum.flat_map(&enforce_ceiling(&1, max_bytes))
    |> Enum.reject(&(&1.text == ""))
  rescue
    e ->
      # A parse failure must not lose the document. Indexing it whole is worse
      # than chunking it and better than dropping it.
      Logger.warning("[SectionChunker] falling back to whole document: #{Exception.message(e)}")
      [%{text: String.trim(markdown), path: [], terms: []}]
  end

  defp parse(markdown), do: MDEx.parse_document!(markdown, @parse_opts)

  @doc """
  Every heading in `markdown`, as `{level, text, code_text, first_line, last_line}`.

  The raw heading split, before any of the size logic below — merging undersized
  sections and splitting oversized ones would destroy the correspondence between
  a heading and its anchor, which is what
  `StdioMcp.Docs.TarballIngestion.markdown_section/2` needs.

  `text` and `code_text` are separated deliberately. ExDoc writes two kinds of
  heading and they anchor differently:

      prose section   "## Provided options"   ->  "module-provided-options"
      member heading  "# `bind_value`"        ->  "t:bind_value/0"

  Read off the AST the difference is structural — a member heading is a
  `%MDEx.Code{}` span with no prose beside it — where from the raw source it can
  only be guessed at, and guessing failed: slugifying strips underscores as
  emphasis markers, turning `bind_value` into `bindvalue`.

  `last_line` runs to the line before the next heading of any level, or to the
  end of the document.
  """
  @spec headings(String.t()) :: [
          {pos_integer(), String.t(), String.t(), pos_integer(), pos_integer()}
        ]
  def headings(markdown) when is_binary(markdown) do
    total = markdown |> String.split("\n") |> length()

    found =
      markdown
      |> parse()
      |> Map.fetch!(:nodes)
      |> Enum.filter(&match?(%MDEx.Heading{}, &1))
      |> Enum.map(fn %MDEx.Heading{level: level} = node ->
        {start_line, _} = node.sourcepos.start
        {level, literals(node, MDEx.Text), literals(node, MDEx.Code), start_line}
      end)

    starts = Enum.map(found, fn {_l, _t, _c, line} -> line end) ++ [total + 1]

    found
    |> Enum.zip(tl(starts))
    |> Enum.map(fn {{level, text, code, from}, next} -> {level, text, code, from, next - 1} end)
  rescue
    _ -> []
  end

  defp literals(node, struct) do
    node
    |> Enum.filter(&(is_struct(&1) and &1.__struct__ == struct))
    |> Enum.map_join(& &1.literal)
    |> String.trim()
  end

  # -- 1. Heading boundaries ---------------------------------------------------

  # The heading node stays in the section's own body. Dropping it would remove
  # the single most searchable line in the section from the keyword index, while
  # keeping it in `path` only serves the embedding.
  defp sections(%MDEx.Document{nodes: nodes}) do
    {sections, open} = Enum.reduce(nodes, {[], new_section([])}, &place_node/2)

    [open | sections] |> Enum.reverse() |> Enum.reject(&(&1.nodes == []))
  end

  defp place_node(%MDEx.Heading{level: level} = node, {sections, open})
       when level <= @section_level do
    # `take(level - 1)` is what makes the trail a trail: an h2 after
    # `["Server", "Tools"]` replaces "Tools" rather than nesting under it.
    path = Enum.take(open.path, level - 1) ++ [heading_text(node)]

    {flush(open, sections), %{new_section(path) | nodes: [node]}}
  end

  defp place_node(node, {sections, open}), do: {sections, %{open | nodes: open.nodes ++ [node]}}

  defp new_section(path), do: %{path: path, nodes: []}

  defp flush(%{nodes: []}, sections), do: sections
  defp flush(section, sections), do: [section | sections]

  defp heading_text(%MDEx.Heading{} = node) do
    node
    |> Enum.filter(&match?(%MDEx.Text{}, &1))
    |> Enum.map_join(& &1.literal)
    |> String.trim()
  end

  # -- Navigation detection ----------------------------------------------------

  defp navigation?(%{nodes: nodes}) do
    body = Enum.reject(nodes, &match?(%MDEx.Heading{}, &1))
    items = Enum.flat_map(body, &list_items/1)

    body != [] and
      Enum.all?(body, &match?(%MDEx.List{}, &1)) and
      items != [] and
      not Enum.any?(nodes, &match?(%MDEx.CodeBlock{}, &1)) and
      Enum.count(items, &starts_with_internal_link?/1) * 3 >= length(items) * 2
  end

  defp list_items(%MDEx.List{nodes: items}), do: items
  defp list_items(_node), do: []

  defp starts_with_internal_link?(%MDEx.ListItem{
         nodes: [%MDEx.Paragraph{nodes: [first | _]} | _]
       }),
       do: internal_link?(first)

  defp starts_with_internal_link?(_item), do: false

  defp internal_link?(%MDEx.Link{url: url}) when is_binary(url) do
    not String.match?(url, ~r{^([a-z][a-z0-9+.-]*:|//)}i)
  end

  defp internal_link?(_node), do: false

  # -- 2/3/4. Size ceiling -----------------------------------------------------

  defp split_oversized(section, max_bytes, lines) do
    if node_size(section.nodes, lines) <= max_bytes do
      [section]
    else
      {heading, body} = Enum.split_with(section.nodes, &match?(%MDEx.Heading{}, &1))

      body
      |> Enum.flat_map(&explode(&1, max_bytes, lines))
      |> group(max_bytes, lines)
      |> prepend_heading(heading)
      |> Enum.map(&%{path: section.path, nodes: &1})
    end
  end

  # A list larger than the budget is opened into its items, so grouping can pack
  # whole options together instead of cutting through one. The items are used
  # directly — they carry their own `sourcepos`, so slicing reproduces the exact
  # source lines and no rewrapping into a synthetic parent list is needed.
  #
  # Any other oversized block (in practice a long code sample) passes through
  # whole and is dealt with by `enforce_ceiling/2` after slicing, which is the
  # only step allowed to cut inside a syntactic unit.
  defp explode(%MDEx.List{nodes: items} = list, max_bytes, lines) do
    if node_size([list], lines) > max_bytes, do: items, else: [list]
  end

  defp explode(node, _max_bytes, _lines), do: [node]

  defp group(nodes, max_bytes, lines) do
    nodes
    |> Enum.reduce([[]], fn node, [current | rest] ->
      cond do
        current == [] -> [[node] | rest]
        node_size(current ++ [node], lines) <= max_bytes -> [current ++ [node] | rest]
        true -> [[node], current | rest]
      end
    end)
    |> Enum.reverse()
    |> Enum.reject(&(&1 == []))
  end

  # The heading goes on the first piece only. Repeating it on every piece would
  # restore the duplication this chunker exists to remove — `path` is what carries
  # the context to the others.
  #
  # Groups come first because this sits in a pipe. Written heading-first it read
  # naturally and was wrong: the piped groups bound to `heading`, `[]` bound to
  # the group list, and the `(_heading, [])` clause returned `[]` — so every
  # section large enough to need splitting was silently dropped, which is
  # indistinguishable from a document that legitimately produced no chunks.
  defp prepend_heading(groups, []), do: groups
  defp prepend_heading([], _heading), do: []
  defp prepend_heading([first | rest], heading), do: [heading ++ first | rest]

  # -- Size floor --------------------------------------------------------------

  # Merges forward rather than backward: a short lead-in followed by its examples
  # reads as one unit, and the heading is on the short piece.
  defp merge_undersized(sections, min_bytes, max_bytes, lines) do
    sections
    |> Enum.reverse()
    |> Enum.reduce([], fn section, acc ->
      merge_step(section, acc, min_bytes, max_bytes, lines)
    end)
  end

  defp merge_step(section, [], _min, _max, _lines), do: [section]

  defp merge_step(section, [next | rest] = acc, min_bytes, max_bytes, lines) do
    combined = section.nodes ++ next.nodes

    if node_size(section.nodes, lines) < min_bytes and
         node_size(combined, lines) <= max_bytes and
         same_subtree?(section.path, next.path) do
      [%{path: common_prefix(section.path, next.path), nodes: combined} | rest]
    else
      [section | acc]
    end
  end

  # Only merge within one heading subtree. Joining the tail of "Examples" onto the
  # head of an unrelated section would produce a chunk whose breadcrumb is a lie.
  defp same_subtree?([], _other), do: true
  defp same_subtree?(_path, []), do: true
  defp same_subtree?([a | _], [b | _]), do: a == b

  defp common_prefix(a, b) do
    a |> Enum.zip(b) |> Enum.take_while(fn {x, y} -> x == y end) |> Enum.map(&elem(&1, 0))
  end

  # -- Slicing the source ------------------------------------------------------

  # The text comes out of the original markdown, sliced by the line span the AST
  # reports, rather than out of `MDEx.to_markdown/2`.
  #
  # Rendering the AST back to markdown looked equivalent and was not: a CommonMark
  # writer escapes anything that could be re-parsed as syntax, so
  # `client_credentials` came back as `client\_credentials`. Measured after the
  # first re-index — 0 rows containing the literal identifier, 16 rows carrying
  # stray backslashes — which silently broke an eval expectation and would have
  # broken every exact-identifier search against those docs. Rendering also
  # emitted `<!-- end list -->` between the single-item lists produced by
  # exploding a list, needing a coalescing pass to remove.
  #
  # Slicing has neither problem and is cheaper: no writer, and size checks are a
  # subtraction over line offsets instead of a full render.
  defp render(%{path: path, nodes: nodes}, lines),
    do: %{text: slice(nodes, lines), path: path, terms: terms(nodes)}

  # -- Naming a fragment by what is in it --------------------------------------

  # Only a *leading* code span counts. An option list item reads
  # "* `:busy_timeout` - Sets the busy timeout…", so the first inline code is the
  # thing being documented; a code span anywhere else in the item is one of the
  # values it can take (`:on`, `:memory`) and naming the chunk after those would
  # be worse than the ordinal it replaces. The structural test is the same one
  # `starts_with_internal_link?/1` uses for navigation detection.
  defp terms(nodes) do
    nodes
    |> Enum.flat_map(&leading_term/1)
    |> Enum.uniq()
    |> Enum.take(@max_terms)
  end

  # A list arrives whole when the section fitted, and exploded into bare items
  # when `split_oversized/3` opened it, so both shapes have to be handled.
  defp leading_term(%MDEx.List{nodes: items}), do: Enum.flat_map(items, &leading_term/1)

  defp leading_term(%MDEx.ListItem{nodes: [%MDEx.Paragraph{nodes: [first | _]} | _]}),
    do: code_literal(first)

  defp leading_term(_node), do: []

  defp code_literal(%MDEx.Code{literal: literal}) do
    case String.trim(literal) do
      "" -> []
      term -> [term]
    end
  end

  defp code_literal(_node), do: []

  defp slice([], _lines), do: ""

  defp slice(nodes, lines) do
    {first, last} = line_span(nodes)

    lines
    |> Enum.slice((first - 1)..(last - 1)//1)
    |> Enum.join("\n")
    |> String.trim()
  end

  # Sections and groups are contiguous runs of sibling nodes, so the span from the
  # earliest start line to the latest end line is exactly the text they cover —
  # blank lines between them included, which is what keeps the markdown valid.
  defp line_span(nodes) do
    starts = Enum.map(nodes, fn node -> elem(node.sourcepos.start, 0) end)
    ends = Enum.map(nodes, fn node -> elem(node.sourcepos.end, 0) end)

    {Enum.min(starts), Enum.max(ends)}
  end

  defp node_size(nodes, lines), do: nodes |> slice(lines) |> byte_size()

  # -- The floor ---------------------------------------------------------------

  # Reached only when a single block is larger than the budget — in practice one
  # long code sample, which no structural boundary can divide. Applied to the
  # sliced text rather than to nodes, because this is the one step that cuts
  # inside a syntactic unit and therefore has nothing to slice by.
  defp enforce_ceiling(%{text: text} = chunk, max_bytes) when byte_size(text) <= max_bytes,
    do: [chunk]

  defp enforce_ceiling(%{text: text, path: path, terms: terms}, max_bytes) do
    case TextChunker.split(text, chunk_size: max_bytes, chunk_overlap: 0, format: :markdown) do
      pieces when is_list(pieces) ->
        pieces
        |> Enum.map(& &1.text)
        |> balance_fences()
        |> Enum.map(&%{text: String.trim(&1), path: path, terms: reparse_terms(&1, terms)})

      other ->
        Logger.warning("[SectionChunker] byte split failed (#{inspect(other)}) — keeping whole")
        [%{text: text, path: path, terms: terms}]
    end
  end

  # Each piece is renamed from its own text rather than inheriting the whole
  # chunk's terms. Copying them down was written off as affecting only the rare
  # single-oversized-code-block case; measured, `Ecto.Adapters.SQLite3`'s
  # "Provided options" comes through here and produced three chunks all named
  # "— :database" — the identical-siblings problem this naming exists to remove,
  # rebuilt one layer down.
  #
  # A byte cut can land mid-item, so a piece may open with a continuation line
  # and parse to no list items at all; it keeps the parent's terms rather than
  # falling back to an ordinal, since a shared name is still better than none.
  defp reparse_terms(text, fallback) do
    case terms(parse(text).nodes) do
      [] -> fallback
      terms -> terms
    end
  rescue
    _ -> fallback
  end

  # -- Fence balancing (only reachable via enforce_ceiling/2) -------------------

  defp balance_fences(chunks) do
    {balanced, _open?} =
      Enum.map_reduce(chunks, false, fn chunk, open? ->
        chunk = if open?, do: "```\n" <> chunk, else: chunk
        now_open? = chunk |> String.split("```") |> length() |> rem(2) == 0

        {if(now_open?, do: chunk <> "\n```", else: chunk), now_open?}
      end)

    balanced
  end
end

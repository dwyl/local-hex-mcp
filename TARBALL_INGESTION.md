# Tarball Ingestion, step by step

How Hex package documentation moves from a compressed tarball on `repo.hex.pm` to zero-disk memory extraction, HTML/Markdown structural parsing, chunking, parallel AI embedding, and atomic SQLite storage.

---

## Moving Parts & Core Modules

- **`StdioMcp.Docs.TarballIngestion`** — Main coordinator for acquisition, extraction, parsing, embedding, and storage.
- **`StdioMcp.Docs.SectionChunker`** — Structural AST chunker (powered by `MDEx` AST parsing) that splits text at headings, blocks, and list items while balancing code fences.
- **`LazyHTML`** — C-based Lexbor HTML DOM parser for extracting DOM content, isolating `#content`, and stripping UI chrome.
- **`StdioMcp.AI.Client`** — HTTP client for provider embedding endpoints.
- **`StdioMcp.Docs.EmbeddingConfig`** — Singleton table enforcing the single-model vector space invariant in SQLite.
- **`StdioMcp.Repo` & SQLite Triggers** — Atomic storage and automatic FTS5 full-text index synchronization (`package_docs_ai`).

---

## The Pipeline Sequence

```txt
1. Model Check
➔  2. Download
➔  3. Path-Normalized Extract
➔  4. Index & Source Build
➔  5. Markdown/HTML Resolution
➔  6. Structural Chunking
➔  7. Parallel Batch Embedding + Bisection + Model Record
➔  8. Atomic SQLite Save
```

---

### Step 1: Pre-Flight Vector Space Invariant Check

```elixir
with :ok <- EmbeddingConfig.allow_ingest(Client.embed_model())
```

Before making any HTTP network request, `ingest/3` queries `embedding_config` in SQLite.

- If an index already exists built by a *different* embedding model (e.g. `mistral-embed` vs `codestral-embed`), ingestion **refuses to proceed immediately**.
- **Ordering rationale**: Proceeding with a different model would consume bandwidth and API credits to produce vectors of incompatible dimensions that cannot be searched alongside existing rows.

---

### Step 2: Download & Path-Normalized Memory Extraction

```elixir
{:ok, tarball} <- download(package, version),
{:ok, %{} = files} <- extract(tarball)
```

1. **HTTP GET**: Fetches `https://repo.hex.pm/docs/{package}-{version}.tar.gz` with a strict 120-second timeout ceiling (`@request_timeout`).
2. **In-Memory Unpack**: `:erl_tar.extract({:binary, tarball}, [:memory, :compressed])` unpacks the tarball into an in-memory map of binary content. Zero files are written to disk.
3. **Path Normalization**: Strips leading `./` from entry names (`String.replace_prefix("./", "")`).
   - *Why*: Tarballs disagree on prefixes (`req` ships `dist/search_data-*.js`, while Elixir core ships `./dist/search_data-*.js`). Downstream lookups use anchored regexes (`~r{^dist/…}`) or exact filenames (`base <> ".md"`), so a leading `./` defeated every matcher at once — causing the Elixir standard library to fail as `:no_index_in_tarball` while the index sat in the tarball unmatched.

---

### Step 3: Search Index & Source Link Map Construction

```elixir
{:ok, items} <- read_index(files),
sources = source_index(files)
```

1. **Search Index Resolution (`read_index/1`)**:
   - Tries `dist/search_data-*.js` (ExDoc search index carrying text for modules, functions, types, callbacks, and guides).
   - Falls back to `dist/sidebar_items*.js` for older ExDoc packages.
2. **Source Link Extraction (`source_index/1`)**:
   - Scans HTML anchors for `"View Source"` / `@chrome_classes` (`detail-link`, `view-source`, `hover-link`, `icon-action`).
   - Maps item references (`ref`, e.g. `Phoenix.Router.html#connect/1`) to exact GitHub source URLs (e.g. `blob/v1.8.9/lib/phoenix/router.ex#L1428`).

---

### Step 4: Markdown vs. HTML Section Resolution (`build_docs/4`)

For every item in the search index, `build_docs/4` resolves its documentation text via `page_content(ref, files)`:

```elixir
# page_content/2 resolution strategy:
1. Try Markdown (.md) section ➔ markdown_section(md, anchor)
2. Fallback to HTML (.html) section ➔ html_section(html, anchor)
3. Fallback to "" ➔ Retain title-only doc (preventing page duplication across siblings)
```

#### Case A: Markdown Resolution (`.md`)

- Looks for `base <> ".md"` (e.g. `Phoenix.Router.md`).
- Uses `SectionChunker.headings/1` to parse the Markdown AST (`MDEx`), locating the exact line range for the requested heading/anchor.
- **Missing Anchor Protection**: If an anchor cannot be located in `.md`, it returns `""` instead of the whole file. Returning `""` lets execution fall through to HTML rather than duplicating a 14KB document across 36 function entries.

#### Case B: HTML Resolution (`.html`)

- Parses `page.html` with `LazyHTML.from_document()`.
- **Chrome Stripping (`content_root/1`)**: Isolates `<div id="content">` or `<main>`, discarding sidebars, footers, theme toggles, and modals.
- **Section Narrowing (`narrow_to_anchor/2`)**: Locates the specific DOM node matching `id="anchor"`.
- **AST Walk (`node_text/2`)**:
  - Contextual whitespace tracking: preserves spaces and indentation inside `<pre>` (`pre? = true`), collapses whitespace outside `<pre>`.
  - Wraps `<pre>` blocks in Markdown code fences (```).
  - Converts HTML tables (`<tr>`, `<td>`, `<th>`) into Markdown pipe tables (`| col1 | col2 |`).
  - Drops elements matching `@chrome_classes` (`detail-link`, `view-source`, `hover-link`, `icon-action`).

---

### Step 5: Structural Section Chunking (`SectionChunker.chunk/1`)

Extracted text is split into chunks (default `@default_max_bytes`: 1600 bytes, configurable via `opts`):

1. **AST Boundaries**: Splits text strictly at headings (`@section_level`: 3), paragraphs, lists, and code blocks. Code blocks are kept atomic and are never cut in normal AST chunking.
2. **Breadcrumbs & Terms**: Attaches heading paths (`path`, e.g. `["Allowed options"]`) and extracted inline option terms (`terms`, e.g. `:busy_timeout, :journal_mode`) to chunk signatures.
3. **Fence Balancing (`balance_fences/1`)**: If a single oversized code block exceeds `max_bytes`, raw byte-splitting is applied, and `balance_fences/1` uses `map_reduce` parity tracking to close/re-open ``` code fences across split boundaries.

---

### Step 6: Parallel Batch Embedding, Token Bisection & Model Configuration Recording (`attach_embeddings/1`)

```elixir
batches = Enum.chunk_every(docs, embed_batch_size()) # Default: 200 items/batch

batches
|> Task.async_stream(&embed_batch/1,
  max_concurrency: embed_concurrency(), # Default: 2
  ordered: true,
  timeout: @embed_batch_timeout,        # 180_000 ms
  on_timeout: :kill_task
)
```

1. **Batching & Stream Execution**:
   - Groups chunk maps into batches (default size 200, configurable via `EMBED_BATCH_SIZE`).
   - Executes via `Task.async_stream` with `max_concurrency: 2` (configurable via `EMBED_CONCURRENCY`), `timeout: 180_000`, and `on_timeout: :kill_task`.
2. **Rate Limit Backoff (HTTP 429)**:
   - Max 5 total attempts (`@embed_max_attempts`: initial attempt plus up to 4 retries) honoring `Retry-After` headers or exponential backoff (`1s` to `30s`).
3. **Token Limit Bisection (HTTP 400 / Code 3210)**:
   - If a batch of text chunks exceeds the provider's token window (HTTP 400 token overflow), `split_batch/3` **recursively bisects the batch in half** (200 ➔ 100 + 100 ➔ 50) and embeds each half sequentially.
4. **Recording Model Configuration (`record_embedding_config/1`)**:
   - Executed **inside `attach_embeddings/1` immediately after the stream reduction completes**, before `save/3` runs:

     ```elixir
     {:ok, acc, _done} ->
       embedded = acc |> Enum.reverse() |> Enum.concat()
       record_embedding_config(embedded)
       {:ok, embedded}
     ```

   - **Rationale**: Reads the actual vector length from returned vectors (`length(vector)`) so the recorded dimension is empirical evidence from the provider rather than an unverified restatement of configuration. Written after embedding succeeds so a failed ingest leaves the previous record — and previous database rows — intact.
5. **Fail-Fast Policy**:
   - If any batch fails or returns `nil` vectors, **the entire ingestion aborts immediately**. Rows with missing embeddings are never written to SQLite.

---

### Step 7: Atomic Storage & SQLite Synchronization (`save/3`)

```elixir
Repo.transaction(fn ->
  Repo.delete_all(from(d in PackageDoc, where: d.package == ^package and d.version == ^version))
  Repo.insert_all(PackageDoc, entries)
end)
```

1. **Atomic Transaction**:
   - Deletes old rows for `{package, version}`.
   - Bulk-inserts the newly embedded `package_docs` rows.
2. **Automatic FTS5 Sync**:
   - SQLite `AFTER INSERT` trigger (`package_docs_ai`) populates `package_docs_fts` automatically.
3. **Completion Signal**:
   - Returns `{:ok, rows_written, version}` to `IngestionJob`, which dispatches `{:ingestion_done, key, result}` to all waiting caller PIDs.

---

## Key Ordering Constraints & Design Guarantees

1. **Model Check Before Download**: Validating `embedding_config` before network requests prevents wasteful HTTP downloads and credit consumption on incompatible vector spaces.
2. **Path Normalization Before Matching**: Normalizing `./` prefixes in `extract/1` before any index or page lookup runs prevents anchored regexes (`~r{^dist/…}`) and exact filename lookups from silently missing valid tarball entries.
3. **Sub-document Anchor Isolation**: Returning `""` when a Markdown anchor is missing prevents repeating an entire 14KB module file across dozens of function rows, while falling through cleanly to HTML.
4. **Model Configuration Recording Before `save/3`**: `record_embedding_config` runs in `attach_embeddings/1` after embedding succeeds, deriving vector dimensions directly from returned payload vectors. This guarantees that an aborted or failed embedding step leaves both previous database rows and previous model records untouched.
5. **Fail-Fast Embedding**: Aborting on embedding failure prevents "partially indexed" packages that pass count checks but remain invisible to vector search.
6. **Single Transaction Swap**: Existing package rows are deleted and inserted in a single SQLite transaction, ensuring readers never see a partial index during re-ingestion.

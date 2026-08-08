# How search works — 2026-08-07

Current as of the `signature`-aware reranker, content-named chunks and `limit: 10`.
Everything below the **Archive** divider predates one or more of those and its
numbers are not comparable to these.

## Two arms, one fusion

```
query ─┬─ QuerySanitizer ──→ FTS5 / BM25    top 15 ┐
       └─ embed (1024-dim) → sqlite-vec     top 15 ┴─→ RRF k=60 ─→ top 10 ─→ returned
                                                            └─(optional)→ cross-encoder
```

Both arms join `base_query`, so package/version scoping applies *before* the depth
cut — ranking the whole FTS table and filtering afterwards would spend the 15-item
budget on other packages.

```
28 queries · corpus 11 packages / 3891 rows · top 10

all           recall@10   MRR@10   cand    ms        concept (16)   symbol (12)
fts               0.93      0.67   0.93     4        0.88 / 0.51    1.00 / 0.88
vector            0.93      0.75   1.00    37        0.94 / 0.68    0.92 / 0.83
hybrid            0.93      0.75   0.93    32        0.88 / 0.66    1.00 / 0.86
rrf               1.00      0.75   1.00    28        1.00 / 0.63    1.00 / 0.92
```

Re-baselined 2026-08-07 after `anubis_mcp` went 1.14.0 -> 2.0.0 (1299 -> 1223
docs, corpus 3967 -> 3891 rows). Recall did not move; MRR drifted 0.01-0.02, which
is what a corpus change looks like — **BM25 is collection-global**, so re-indexing
any package shifts the keyword ranking of queries in every other one. All 28
queries still resolved their expectations across a major version, which is the
check that matters: a silently broken expectation shows up as a lower query count,
not as a worse score.

**The fusion is where the retrieval quality is.** It is a *union*, not an
intersection: a document only one arm found can still surface, and the arms fail
differently — FTS misses conceptual phrasing, the bi-encoder misses exact
identifiers. Union takes recall@10 from 0.93 to 1.00. `hybrid` is the intersection
this replaced, kept as the control.

**Deeper arms measure worse.** RRF scores consensus: an item ranked ~15 by both
arms contributes `1/75 + 1/75` and outscores one ranked 3 by a single arm at
`1/63`. At 40-deep there are enough mediocre-but-agreed items to push a strong
single-arm hit out of the fused ten. 15 is the setting; 40 was worse.

**`k` does not matter.** Swept 0, 5, 10, 20, 60 — identical to two decimals on
every bucket. Over ten items, ordering by `Σ 1/(k+rᵢ)` approximates rank-sum at
large `k` and weights the head at `k=0`, and those disagree only when an item is
extreme on one list and middling on the other. Recorded as a null so nobody
re-runs it.

## Chunks are named by what is in them

`signature` is displayed, indexed by FTS, embedded by `embed_text/1`, and read by
the reranker. For a section too large to keep whole it is the *only* field that
differs between slices — `module`, `function` and `hexdocs_url` are shared, and
correctly so, since the slices really do live at one anchor.

Naming them by ordinal defeats that. `Exqlite.Connection.connect/1` splits into
four parts, and as "Part 1".."Part 4" nothing said which held `:journal_mode`; the
cross-encoder ranked it sixth for a query about write-ahead logging. Now:

```
Exqlite.Connection.connect/1 — :database, :default_transaction_mode, :mode, :journal_mode
Exqlite.Connection.connect/1 — :foreign_keys, :cache_size, :cache_spill, …
```

read off the leading inline-code span of each top-level list item. Priority is
**identity, then context, then ordinal**: terms if the chunk has any, else the
heading trail, else `- Part N`. Byte-split pieces re-derive their own terms rather
than inheriting the parent's — copying them down was assumed to affect only the
rare oversized-code-block case and in fact produced three chunks of
`Ecto.Adapters.SQLite3`'s option list all named `— :database`.

430 rows (10.8%) still carry a bare ordinal. They are prose splits — `mix
phx.gen.html - Part 1/2` — with no leading code span to harvest. Their opening
sentences would name them; unimplemented.

## The reranker is optional, and off

It **never adds recall**. Candidate recall after fusion is already 1.00, so the
stage only reorders a pool that already holds the answer — and with `limit 10`
against a rerank depth of 10, it reorders exactly the set that is returned. It
cannot add or remove a document.

That matters because of who reads the output: an LLM that reads every row before
replying. It ranks the payload itself, so rank *within* the payload is close to
worthless, while a document that never arrives cannot be recovered without a
second round trip — which costs far more than the ~2k tokens the extra five rows
add. Measured on the final code:

```
                      recall@10   MRR@10   concept MRR   symbol MRR      ms
no reranker              1.00      0.76       0.65          0.92         41
MiniLM-L4-v2             1.00      0.81       0.67          1.00        291
bge-reranker-base        1.00      0.82       0.68          1.00       1952
```

Measured on the 3967-row corpus, before the `anubis_mcp` 2.0.0 bump. The three are
internally comparable — same corpus, one variable — but not directly against the
table above; on 3891 rows the no-reranker row reads 1.00 / 0.75 / 0.63 / 0.92.

Recall is identical by construction, not by luck. What reranking buys is **symbol
MRR, 0.92 → 1.00** — twelve identifier queries all landing at rank 1 — and +0.02
on concepts.

### Re-measured at top-5 on EMLX (Apple GPU), 3891 rows

The table above is `limit 10` on the older 3967-row corpus. The current default
regime — top-5, 15 per arm, rerank depth 10 — with `MiniLM-L4-v2` compiled by
EMLX on the GPU rather than EXLA on CPU:

```
all (28)      recall@5   MRR@10      cand        ms
rrf                 0.96      0.75      1.00        29
rrf+rerank          0.96      0.78      1.00        90

concept (16)  recall@5   MRR@10      cand        ms
rrf                 0.94      0.63      1.00        42
rrf+rerank          0.94      0.62      1.00       105

symbol (12)   recall@5   MRR@10      cand        ms
rrf                 1.00      0.92      1.00        23
rrf+rerank          1.00      1.00      1.00        86
```

Two things this shows that the aggregate hides.

**The MRR gain is entirely symbol queries.** +0.08 there, −0.01 on concepts. The
headline +0.03 is an average of two opposite effects, and the class that most
needs help — concepts, at MRR 0.62 — gets none. On 12 and 16 queries these are
one or two documents moving a single rank, so the concept figure is "no gain",
not "harm"; the symbol saturation is the more trustworthy of the two.

**The stage costs 61–63ms, not ~250ms.** That is the EMLX/GPU figure. Measured
in isolation the same serving runs 57.8ms median against EXLA's 246.1ms for a
batch of 10 at sequence length 512, so the end-to-end delta agrees with the
microbenchmark. The ~250ms figure quoted elsewhere in this file is EXLA on CPU
and remains correct for Linux. Any latency claim about this stage has to name
the backend.

Conclusion is unchanged: **off**. A 3.1× slowdown for rank-within-the-payload is
still a bad trade for a consumer that reads the whole payload — the cheaper stage
does not make rank matter more.

**Default: off.** `AI_RERANK_MODEL` unset means no model is loaded at all, which
also removes a HuggingFace download and an EXLA compile from
`Application.start/2` — they happened inside the window an MCP client waits for
the server to come up, so a cold machine's first connection could time out and
look broken.

**If you want one: `MiniLM-L4-v2`.** +250ms on EXLA/CPU, +61ms on EMLX/Apple GPU.
Worth it only if something downstream reads position rather than the page — and
specifically only if it asks symbol-shaped questions, since that is where the
whole gain lives.

**Not bge.** It buys +0.01 MRR over L4 — a sixth of a rank — for another 1661ms.
Its one real edge was strictness: on `"Building a Server"` it was the only model
that pushed the sibling `building-a-client` guide out of the top five entirely,
monotone in capacity (L2 rank 2, L4 2, L6 3, L12 4, bge absent). Returning ten
makes that moot — the document is in the payload either way. **The `limit 10`
decision is what removed the argument for capacity.** If a token-constrained
client ever cuts to top-3, strictness matters again and this reopens.

### Model names

HuggingFace renamed these: **no dash before the layer count, lowercase `v`.**
Checked against the API on 2026-08-07 — `200` is canonical, `307` redirects (works,
but is not the real name), `401` does not exist:

```
cross-encoder/ms-marco-MiniLM-L4-v2      200   canonical
cross-encoder/ms-marco-MiniLM-L6-v2      200
cross-encoder/ms-marco-MiniLM-L12-v2     200
cross-encoder/ms-marco-TinyBERT-L2-v2    200
cross-encoder/ms-marco-TinyBERT-L4       200
BAAI/bge-reranker-base                   200

cross-encoder/ms-marco-MiniLM-L-6-v2     307   old dashed form, redirects
cross-encoder/ms-marco-MiniLM-L4-V2      307   ids are case-insensitive
cross-encoder/ms-marco-TinyBERT-L-4-v2   401   does not exist in either scheme
```

The last one circulates in model lists and is the realistic way to get this wrong:
the `-v2` suffix belongs to the L2 line, not L4. It used to abort application
startup — `{:ok, _} = Bumblebee.load_model/1` raised inside `start/2`, so a typo
in an env var meant an MCP server that would not come up, with the reason on a
stderr stream the client discards. It now logs at `error` (the configured level;
a warning would have been dropped) and starts without reranking.

`TinyBERT-L2-v2` is the one to reject among the small models: it loses a query L4
keeps. `TinyBERT-L6` is worse — 0.90 symbol MRR, the only model that fails the
case every other one gets perfect, and slower than MiniLM-L6.

**When enabled, the strategy is `fused`**: RRF of the retrieval order with the
reranked one, so the model can move a document but not overrule retrieval. Kept on
the mechanistic argument — a bi-encoder and a cross-encoder fail differently — and
explicitly **not** on the measurement, which is one query wide. See the audit in
the archive.

## Cost of the tail

All ten rows come back and nothing ranks the last five. Expect changelog entries
and loosely-related functions there: a live exqlite search returned three
changelog rows at 4, 6 and 8. That is the accepted cost of not letting a small
model expel a good row, and it is also three wasted slots — down-weighting
changelog `doc_type` is the cheapest unclaimed win.

## The embedding model is the index

Every vector in `package_docs` — and in `knowledge` — must come from one model.
Two models are never comparable, and the failure has two shapes of which the
quiet one is worse: different dimensions make sqlite-vec raise, while *identical*
dimensions raise nothing at all and return noise. `mistral-embed` and
Qwen3-Embedding-0.6B are both 1024-dim, so that second case is not hypothetical.

`embedding_config` holds one row naming the model and dimension that built the
index. Ingestion refuses a mismatch before downloading anything; `Docs.Search`
disables the vector arm and says so in `notices`; `Memory` skips neighbour search
in `remember` rather than deduplicating on meaningless distances.
`mix docs.reindex` is the only supported way to change models.

### Two ways a partial reindex used to defeat that

Both found on 2026-08-07 by nearly doing them.

**Interruption.** `reindex/3` clears the record, then re-embeds package by package,
and the first success writes the new record. Ctrl-C after package three left
packages 1-3 on the new model, 4-11 on the old one, and the record naming the new
one — so the guard passed and searches against the untouched packages returned
noise. A *failed* package was already handled by dropping its rows; an
interrupted *process* never reaches that code. Every target's rows are now
deleted up front, so an interruption leaves them **absent** rather than stale,
and absent is safe: `Docs.Search` re-ingests on the next search that names them.
The cost is that a wholly failed run empties the index instead of leaving it
usable, which is what `--keep-failed` is for.

**`--only` with a changed model.** Same end state through a different door: the
named packages move, the rest do not, and the global record follows the named
ones. Now refused outright — `--only` is for re-embedding a package that failed,
under the model already in force. Changing models is all-or-nothing.

### The knowledge base was outside the guard

`knowledge` is a second vector space in the same database, embedded by the same
`Client.embed/1` and compared with the same `vec_distance_cosine`, covered by the
same single `embedding_config` row — and `mix docs.reindex` never touched it. So
switching `AI_EMBED_MODEL` moved `package_docs` and left `knowledge` behind.

`Memory.search/2` is FTS-only and was unaffected, which is worth stating because
the first diagnosis said otherwise. The exposure was `process_remember/2`, which
finds neighbours by cosine and applies `@similarity_threshold` to them: with a
mixed index, deduplication decides on noise. Reindex now re-embeds knowledge in
one batch (tens of rows against a package's thousands), and `search_by_vector/2`
consults `EmbeddingConfig` first, returning no neighbours on a mismatch. No
neighbours means `decide/2` creates a new entry — a possible duplicate, which a
later pass can merge, rather than a merge into the wrong entry, which nothing
recovers.

## Local embeddings: fast, and unusable (2026-08-07)

The motivation was real: changing `AI_EMBED_MODEL` costs a full re-embed, which
is billable, so the embedder had never been swept the way rerankers were. A local
endpoint makes that free. `AI_EMBED_URL` and `AI_CHAT_URL` were split out of
`AI_API_URL` for it — an embedding server has no `/chat/completions`, and a single
URL left `remember` calling a route that 404s.

Two servers, same model family, on the same machine:

| | throughput | full reindex | single query |
| --- | --- | --- | --- |
| TEI 1.9.3, candle/Metal, f16 | 244 tok/s | 25-30 min | 48ms |
| MLX, Qwen3-Embedding-0.6B-4bit-DWQ | 2,400 tok/s | ~5 min | 27ms |
| mistral-embed (hosted) | — | ~3 min | network round trip |

MLX is 10x candle here and beats the network on query latency. The performance
case was won outright.

**And the retrieval collapsed.**

```
                mistral-embed    Qwen3-0.6B-4bit
vector recall       0.93              0.43
candidate recall    1.00              0.46
symbol vector       0.92              0.33
rrf (saved by FTS)  1.00              0.96
```

`cand 0.46` means the answer was not in the pool at all, half the time. Direct
measurement of why, none of which found the cause:

```
query <-> the document that answers it    cos 0.089
query <-> a distractor                    cos 0.033
two unrelated sentences                   cos 0.211
```

A relevant pair scoring below two unrelated sentences is not a weaker embedder,
it is a space that does not hold the relation. Three hypotheses died: padding with
`last_token` pooling (embeddings are batch-invariant, `cos 1.0000` alone vs
batched), the instruction prefix Qwen3's card specifies for queries (it made the
ranking *worse*, flipping the correct document below the distractor), and, earlier,
CPU-instead-of-Metal (the startup log said `Metal(MetalDevice(DeviceId(1)))` and
the homebrew formula passes `-F metal` on arm64).

Untested, and the two things that would identify the cause: the **f16** weights,
abandoned before being evaluated, and a symmetric BERT-family model such as
`bge-base-en-v1.5`. So this result condemns one quantised model on this corpus,
not local embedding.

**What it bought.** A bad embedder was identified in one eval run against a corpus
re-embedded in five minutes. That loop is the deliverable; the model was not.

**Measurement notes, both errors made here first.** Timing embeddings with
*identical* inputs measures the server's cache — 200 copies of one string returned
in 0.1s, "347,778 tok/s". And timing a query while an ingest is running measures
`queue_time`, not inference: a single query read 17.6s wall against 48ms of actual
compute, visible only in TEI's own log breakdown. Distinct inputs, and an idle
server.

**Cost, since it was the original motive.** Ingest dominates completely:
`mistral-embed` shows 3422 calls for 6,464,693 tokens — 1,889 per call, all
batches. A search query is ~15 tokens, so a thousand searches is ~0.2% of one
day's spend here. Moving queries local saves nothing worth having; the honest
argument is latency, and that requires committing the whole index to one model.

## The memory subsystem gets the same retrieval (2026-08-07)

Both halves ran a single arm, and they were exactly inverted: `recall` read with
FTS5 alone, `remember` found deduplication candidates with cosine alone. Each was
blind in the way the other was not, and the docs pipeline had already measured
what that costs — the union is worth 0.07 of recall@10 over either arm, because
the arms fail differently.

Both now use `Docs.Fusion.rrf/3` over the same two arms, scoped before the depth
cut. Fusion is used for **candidate recall only, never for ordering**, which is
the role it plays in `Docs.Search` too — and in `remember` that distinction is
load-bearing: the fused set is re-sorted by cosine before `decide/2` sees it, so
`@similarity_threshold`, the nearest-neighbour-rendered-in-full rule and the
prompt all keep the semantics they were calibrated with. The change is confined
to *which* entries are considered.

`recall` still works with no API key: no embedding means the keyword path,
including its `ilike` fallback. A model mismatch takes the same route rather than
comparing across vector spaces.

Measured on the 14-entry base:

```
"my logs are empty even though something clearly went wrong"
   FTS only  MISS        hybrid  rank 1      <- zero lexical overlap
"the server hangs forever when it asks the client for something"
   FTS only  rank 2      hybrid  rank 2
"why did my benchmark numbers move when I added an unrelated package"
   FTS only  MISS        hybrid  MISS
```

One clear win, one tie, one miss for both — and for `remember`, **a verified
no-op**: at 14 entries both arms return the whole base, so fusion adds nothing and
the cosine re-sort reproduces the previous selection exactly, same two neighbours
at the same distances. That is the expected result and the reason to trust the
change: it cannot alter behaviour until the base exceeds the arm depth of 10, and
it is calibrated to do nothing before then.

Worth remembering when judging it: the +0.07 figure comes from 3891 rows across 11
packages. A 14-entry base is one topic, where cosine is topic-dominated — the same
property that forced `@similarity_threshold` from 0.70 to 0.80 — so this corpus
cannot demonstrate the benefit even where it exists.

## Version resolution, proven on a real release (2026-08-07)

Until now the lockfile switch had only been exercised against a contrived
`test_lock/mix.lock` pinning an older `nimble_options`. `anubis_mcp` publishing
**2.0.0** provided the real case, mid-session, with no restart:

```
notices:
  Replaced indexed 'anubis_mcp' v1.14.0 with v2.0.0, which
  /Users/nevendrean/code/local_hex_mcp/mix.lock pins.
  Docs for 'anubis_mcp' v2.0.0 were just indexed (1223 docs)
```

`Lockfile.version/1` re-reads `$PROJECT_ROOT/mix.lock` on every lookup rather than
caching at boot, which is what let a `mix deps.get` performed outside the server
take effect on the next query. The switch, download, chunking and embedding of
1223 documents all completed **inside the tool call** — no "still being indexed"
notice — and the answer came from 2.0.0 rather than the stale 1.14.0.

Two things this validated that the contrived test could not. A *major* version is
where documentation is most likely to be restructured, and all 28 eval
expectations still resolved afterwards. And the answer itself was only correct
because of the switch: 2.0.0 introduces `Anubis.Protocol.Registry` and the
`2025-11-25` protocol version, neither of which exists in 1.14.0 — serving the
indexed version would have produced a confident, wrong answer with nothing
signalling it.

## Things that stay true

- **BM25 is collection-global.** FTS5's `bm25()` uses corpus-wide document
  frequency and average length, so indexing *any* package shifts keyword ranking
  for queries in *other* packages. Vector search is immune. No eval spanning an
  ingest is comparable; the report prints `corpus N packages / M rows` so a
  mismatched comparison is visible rather than silently wrong.
- **The index is single-model**, and that now covers `knowledge` as well as
  `package_docs` — see [The embedding model is the index](#the-embedding-model-is-the-index).
  The lesson generalises: a guard that is checked in one place and bypassed in
  another is not a guard. `embedding_config` was consulted by ingestion and
  search, and ignored by `mix docs.reindex --only`, by an interrupted reindex, and
  by `Memory`. Three holes in one invariant, all silent, all found in a single
  afternoon of actually switching models.
- **One query is 0.04 at n=28.** That is the size of most differences ever claimed
  here. Three separate conclusions in the archive rested on a single query and two
  of them were wrong. Nulls are the robust results; they only need an absence.
- **A query the corpus cannot answer measures coverage, not retrieval.** The
  `client_credentials` query failed every arm for days because boruta documents
  the grant nowhere in prose. It depressed every number while hiding real
  movement.
- **`recall@k` asks "did the expected document appear", never "was the rest of the
  page any good".** A single-target expectation marks at most one row; a good
  result set is several. Every recall number here is a floor on answer quality
  reported as though it described it. `mix docs.eval --judged` and `P@k` exist to
  close that, and `priv/eval/judgements.md` is at 6 of 215 marks.
- **`docs.drift` compares text only.** It cannot see a change to `embed_text/1`,
  to `signature`, or to the embedding model — all of which need `mix docs.reindex`.
- **The value being transformed goes first.** `SectionChunker.prepend_heading/2`
  bound backwards and silently returned `[]`, dropping every oversized section;
  `Reranker.rerank/2` made the same mistake weeks later and blew up on first run.

## Reproducing

```sh
AI_API_KEY=… mix docs.eval --limit 10          # shipped configuration
AI_API_KEY=… mix docs.eval --limit 10 --verbose
AI_RERANK_MODEL=cross-encoder/ms-marco-MiniLM-L4-v2 AI_API_KEY=… mix docs.eval --limit 10
mix docs.eval --modes fts --no-rerank          # needs no API key
mix docs.drift                                 # would a refresh change anything?

# sweeping an embedder, with a local endpoint (free, so it is worth doing)
AI_EMBED_URL=http://localhost:8081/v1 AI_EMBED_MODEL=<model> AI_API_KEY=… \
  mix docs.reindex --yes && mix docs.eval --limit 10
```

Changing `AI_EMBED_MODEL` re-embeds everything, so the eval is the *only* honest
way to judge one: a model that reads well on a benchmark can still collapse
`candidate recall` on this corpus, and one did.

---

# Archive

Everything below is the chronological record of how the above was arrived at,
2026-08-06 to 2026-08-07. **The numbers are not comparable to the tables above or
to each other**: they span three query sets (25, 26, 28), four corpora, a chunker
replacement, a tokenizer change, an embedding-model switch, the `signature`-aware
reranker, and `limit: 5` rather than 10. Several conclusions stated below were
later overturned — where that happened it is noted at the head of the section, and
the head of this file is always the current one.

Kept for the reasoning and the failure modes, not for the measurements.

# Retrieval eval baseline — 2026-08-06

<https://claude.ai/code/artifact/2647ad93-d8f4-400f-bd12-a6bed3de880e?via=auto_preview>

The control for the chunking and fusion work. Re-run `mix docs.eval` after any
change and compare against this table; anything that does not move these numbers
did not work, whatever it looked like in a spot check.

**Corpus**: 9 packages, 2731 docs, all embedded with `mistral-embed` (1024 dims)
after `anubis_mcp` was re-ingested off `codestral-embed`. Chunking is the
`TextChunker` recursive splitter (`chunk_size: 1200`, `chunk_overlap: 100`).
FTS5 is `unicode61` defaults, `sanitize_fts/1` ORs bare words.

```
25 queries · top-5 · 40 candidates per arm

all           recall@5   MRR@10      cand        ms
fts                 0.80      0.59      1.00         6
vector              0.84      0.62      0.96        40
hybrid              0.92      0.69      0.96        32     <- production (intersection)
rrf                 0.92      0.62      1.00        29
rrf+rerank          0.84      0.69      1.00       331

concept (13)  recall@5   MRR@10      cand        ms
fts                 0.69      0.39      1.00         7
vector              0.77      0.39      0.92        54
hybrid              0.85      0.50      0.92        35
rrf                 0.85      0.41      1.00        30
rrf+rerank          0.69      0.40      1.00       335

symbol (12)   recall@5   MRR@10      cand        ms
fts                 0.92      0.81      1.00         5
vector              0.92      0.88      1.00        34
hybrid              1.00      0.90      1.00        27
rrf                 1.00      0.85      1.00        23
rrf+rerank          1.00      1.00      1.00       324
```

What it says:

- **`cand` is at or near 1.00 everywhere.** Retrieval recall is not the problem
  and cannot be improved. Everything left is ranking.
- **The intersection hybrid already in production is the best measured config.**
  RRF ties its recall@5 and ranks worse (MRR 0.62 vs 0.69) — reciprocal rank
  fusion is flat when an arm returns three hits, which is the normal case in a
  single-package corpus. RRF's one real gain is `cand` 1.00 vs 0.96: it rescues
  `[boruta] client_credentials`, which vector search misses outright.
- **The cross-encoder splits hard by query shape.** Perfect on symbols
  (MRR 0.85 -> 1.00, every query at rank 1); a real regression on concepts
  (recall@5 0.85 -> 0.69). Possibly an artefact of truncating arbitrary
  `TextChunker` splits at 1500 chars — worth re-testing after section chunking
  before deciding to gate it.
- **Navigation chunks pollute both arms.** `Next steps` / `Where to go next`
  sections are pure link lists that name the titles being searched for and can
  never answer anything. Five of ten FTS results and four of ten vector results
  for `"Building a Server"`. That is a chunker problem, not a ranking one.

Caveat: 21-25 queries means 0.04 of recall@5 is **one query**. Treat differences
below ~0.08 as noise. What is above noise here: the symbol MRR gain from
reranking, and the concept regression.

Reproduce with `AI_API_KEY=... mix docs.eval --verbose`
(`--modes fts --no-rerank` needs no API key).

## Step 1 — FTS tokenizer sweep (2026-08-06)

An external-content FTS5 table holds only the inverted index, so a tokenizer
variant costs one `'rebuild'` pass over `package_docs` and **no re-embedding** —
seconds and zero API spend. That is what made this measurable at all.

| tokenizer | all r@5 | all MRR | concept r@5 | symbol MRR | cand | rebuild |
| --- | --- | --- | --- | --- | --- | --- |
| `unicode61`, old sanitiser | 0.80 | 0.59 | 0.69 | 0.81 | 1.00 | 13ms |
| **`unicode61`, new sanitiser** | **0.88** | 0.61 | **0.77** | 0.84 | **1.00** | 13ms |
| `tokenchars '_/'` | 0.72 | 0.61 | 0.46 | **0.92** | 0.96 | 13ms |
| `tokenchars '_/.'` | 0.60 | 0.38 | 0.46 | 0.48 | 0.96 | 14ms |
| `tokenchars '_/.:'` | 0.64 | 0.41 | 0.54 | 0.50 | 0.96 | 15ms |
| `trigram` | 0.88 | **0.63** | 0.77 | 0.85 | 0.92 | 81ms |

**The entire gain came from the query sanitiser, not the tokenizer.** Default
`unicode61` is kept, so there is no migration: `QuerySanitizer.to_match/1`
quotes each term as an FTS5 phrase, expands token-char terms into both their
joined and split forms, and drops bare arities. `Boruta.Oauth.token/2` used to
sanitise to `Boruta OR Oauth OR token OR 2` — four common words in a 544-row
package — and ranked **22nd** in its own package. It now ranks **5th** on FTS
alone and **1st** after reranking.

**`tokenchars` is actively harmful.** Gluing `_` makes `chunk_overlap`,
`busy_timeout` and `client_credentials` single tokens that prose can no longer
reach: concept recall collapses 0.77 -> 0.46. Adding `.` is worse still, for the
predicted reason — it ends sentences, so `…uses Req.merge/2.` indexes as
`req.merge/2.` and nothing matches it. Symbol MRR does reach its best value here
(0.92), which is the trade this rejects.

**Trigram was a reasonable instinct.** It ties the winner on recall@5 and edges
MRR by 0.02 (noise at n=25). It loses on `cand` (0.92 vs 1.00) — two queries
whose answer is not in 40 candidates at all, which is a hard ceiling on both RRF
and the cross-encoder — and its index is ~6x more expensive to build. Rejected on
candidate recall, not on ranking.

### After step 1 — new control

```
25 queries · top-5 · 40 candidates per arm

all           recall@5   MRR@10      cand        ms
fts                 0.88      0.61      1.00         1
vector              0.84      0.63      0.96        40
hybrid              0.92      0.69      0.96        31
rrf                 0.92      0.67      1.00        28
rrf+rerank          0.84      0.69      1.00       328

concept (13)  recall@5   MRR@10      cand        ms
fts                 0.77      0.39      1.00         4
vector              0.77      0.40      0.92        40
hybrid              0.85      0.50      0.92        32
rrf                 0.85      0.42      1.00        30
rrf+rerank          0.69      0.40      1.00       332

symbol (12)   recall@5   MRR@10      cand        ms
fts                 1.00      0.84      1.00         1
vector              0.92      0.88      1.00        33
hybrid              1.00      0.89      1.00        25
rrf                 1.00      0.94      1.00        22
rrf+rerank          1.00      1.00      1.00       322
```

Moved: `fts` 0.80 -> 0.88, `rrf` MRR 0.62 -> 0.67 (symbol 0.85 -> 0.94).
`hybrid` is unchanged, because the intersection lets the vector arm do the
ranking — a better keyword arm only widens the set it ranks. `rrf+rerank` is
unchanged in aggregate and still carries the concept regression.

Still failing, all in the same two packages:

- `[boruta] client_credentials` — vector misses outright (rank ·), FTS 15, RRF
  28. The single worst query in the set.
- `[boruta] PKCE` — vector 23.
- `[exqlite] write ahead logging` — reranking pushes it 5 -> 34.

Next: section chunking. The navigation-link chunks and the arbitrary
`TextChunker` splits are what both remaining failure modes have in common.

## Step 2 — MDEx section chunking (2026-08-06)

`SectionChunker` replaces `TextChunker` as the primary splitter: boundaries at
headings, then blocks, then list items, with `TextChunker` kept only as the floor
for a single block over budget. No overlap. Navigation sections dropped. Chunks
carry a heading trail in `signature`, which feeds both the display and the
embedding.

**Same 25 queries, so directly comparable to the table above:**

```
              after step 1        after step 2
all           r@5    MRR          r@5    MRR
fts          0.88   0.61   ->    0.88   0.62
vector       0.84   0.63   ->    0.80   0.68
hybrid       0.92   0.69   ->    0.88   0.73
rrf          0.92   0.67   ->    0.88   0.68
rrf+rerank   0.84   0.69   ->    0.84   0.68

concept(13)
vector       0.77   0.40   ->    0.69   0.49
hybrid       0.85   0.50   ->    0.77   0.56

symbol(12)
fts          1.00   0.84   ->    1.00   0.88
(everything else unchanged)
```

**Honest verdict: a wash on the headline metric.** recall@5 lost 0.04 — one
query, `[exqlite] write ahead logging`, which fell from hybrid rank 4 to 7. MRR
gained across every arm that uses vectors (hybrid 0.69 -> 0.73, concept vector
0.40 -> 0.49): when the right chunk is found it is now ranked better, but no
more chunks are found. `cand` did not move, which was already the warning sign —
it was 1.00 for FTS and RRF before the change and there was nothing there to win.

**What the query set could not see.** None of the 25 queries was
`"Building a Server"` — the case that started this. Measured directly:

```
                    before                          after
FTS   rank 1-2      Next steps link lists           Building a Server (the guide)
VEC   top 10        4 navigation chunks             9 of 10 sections of the guide
```

Navigation chunks are gone (`select count(*) … signature like '%Next steps%'`
-> 0) and both arms now return the guide. That is a real improvement the
aggregate did not register, which is a lesson about the query set rather than
about the chunker. `"Building a Server"` is now query 26; runs from here on are
on **26 queries** and not comparable to the tables above.

**A near miss worth remembering.** The first implementation rendered chunks with
`MDEx.to_markdown/2` instead of slicing the source. A CommonMark writer escapes
anything re-parseable as syntax, so `client_credentials` was stored as
`client\_credentials`: 0 rows with the literal identifier, 16 rows with stray
backslashes, and one eval expectation silently BROKEN. The harness caught it —
the run reported 24 queries instead of 25 — which is the whole argument for
expectations that resolve against the DB rather than being asserted inline.
`SectionChunker` now slices the original markdown by `sourcepos` line spans, so
stored text is byte-identical to what the package published.

### New control — 26 queries

```
all           recall@5   MRR@10      cand        ms
fts                 0.88      0.63      1.00         3
vector              0.81      0.69      0.96        37
hybrid              0.88      0.73      0.96        31
rrf                 0.88      0.69      1.00        27
rrf+rerank          0.85      0.69      1.00       328

concept (14)  recall@5   MRR@10      cand        ms
fts                 0.79      0.42      1.00         5
vector              0.71      0.53      0.93        40
hybrid              0.79      0.59      0.93        32
rrf                 0.79      0.47      1.00        29
rrf+rerank          0.71      0.42      1.00       343

symbol (12)   recall@5   MRR@10      cand        ms
fts                 1.00      0.88      1.00         2
vector              0.92      0.88      1.00        32
hybrid              1.00      0.90      1.00        25
rrf                 1.00      0.94      1.00        22
rrf+rerank          1.00      1.00      1.00       323
```

Corpus: 2702 rows (was 2731), avg content 243 bytes, 2455 distinct.

Still failing, unchanged by chunking:

- `[boruta] client_credentials` — vector still misses outright, RRF 33. The
  vector arm's `cand` of 0.93 on concepts is this one query. Chunking was the
  hypothesis and it was wrong; this needs its own look.
- `[boruta] PKCE` — vector 23.
- `[exqlite] write ahead logging` — reranking still pushes it out (7 -> 26).

The cross-encoder's concept regression survived section chunking, so the
truncation theory is dead: at `sequence_length: 512` on chunks now averaging 243
bytes, nothing is being truncated. Gating it on query shape is now the
straightforward reading of the evidence.

## The `client_credentials` failure was the eval, not the search (2026-08-06)

The one query that failed every arm in every run — vector never found it at all —
turned out to be an invalid test. Worth writing down, because it silently taxed
every measurement above.

**Query**: "let a backend service obtain a token with no user involved",
expecting `{:content, "client_credentials"}`.

**The expectation resolved to three rows**, and all three are `iex>` examples
where `client_credentials` appears as a string literal in a params map:

```
[42906] Examples - Boruta.Oauth.Request.token_request/1
[43006] Examples - Boruta.Oauth.Validator.validate/2
[43033] How to create an OAuth client   (a `supported_grant_types` list)
```

None of them explains the grant. **boruta does not document it in prose at all.**
The only conceptual home is `Boruta.Oauth.ClientCredentialsRequest`, whose entire
moduledoc is the four words "Client credentials request".

**Retrieval was working.** Rank of that module in the vector arm:

| query | rank |
| --- | --- |
| `client credentials grant` | **2** of 544 |
| `machine to machine authentication without a user` | 37 of 544 |
| `let a backend service obtain a token with no user involved` | 357 of 544 |

The question had no answer in the corpus, asked in vocabulary the corpus never
uses. A query a package cannot answer measures **corpus coverage, not
retrieval**, and it depresses every number permanently while hiding real
movement — it is the entire reason concept `cand` read 0.92 instead of 1.00.

Replaced with a question boruta genuinely documents ("restrict access to an HTTP
endpoint using a bearer token", `{:content, "bearer"}`, 6 target rows). Lesson
for adding queries: verify the corpus contains an answer *and* that the answer is
prose, not a code snippet that happens to contain the token.

**Side finding, not yet acted on.** 176 of boruta's 544 rows (32%) hold under 60
bytes of content — stub moduledocs and type docs. For those, `embed_text/1`
produces a string dominated by the module name repeated twice, because `module`
and `signature` are both the module name:

```
"boruta Boruta.Oauth.ClientCredentialsRequest  Boruta.Oauth.ClientCredentialsRequest Client credentials request"
```

De-duplicating the fields before joining is three lines, but it needs a full
re-index to take effect, so it belongs with the next change that requires one.

### New control — 26 queries, corrected set

```
all           recall@5   MRR@10      cand        ms
fts                 0.92      0.67      1.00         3
vector              0.85      0.73      1.00        38
hybrid              0.92      0.77      1.00        31
rrf                 0.92      0.73      1.00        28
rrf+rerank          0.88      0.73      1.00       330

concept (14)  recall@5   MRR@10      cand        ms
fts                 0.86      0.49      1.00         4
vector              0.79      0.60      1.00        41
hybrid              0.86      0.66      1.00        33
rrf                 0.86      0.54      1.00        29
rrf+rerank          0.79      0.50      1.00       339

symbol (12)   recall@5   MRR@10      cand        ms
fts                 1.00      0.88      1.00         2
vector              0.92      0.88      1.00        32
hybrid              1.00      0.90      1.00        26
rrf                 1.00      0.94      1.00        23
rrf+rerank          1.00      1.00      1.00       322
```

`cand` is now **1.00 on every arm** — the 0.92/0.96 readings in every earlier
table were that one invalid query, not a retrieval gap. `[anubis_mcp] Building a
Server` is rank 1 on every arm, and `[boruta] bearer token` rank 1 on every arm.

Remaining genuine failures, all concept queries:

- `[exqlite] write ahead logging` — hybrid 7, and reranking pushes it to 26.
- `[boruta] PKCE` — vector 23, hybrid 13. FTS finds it at 4; the embedder does
  not connect "interception of the authorization code" to PKCE.
- `[anubis_mcp] return an error result from a tool` — FTS 17, though vector
  rescues it at 2.

The cross-encoder still costs 0.07 of concept recall@5 (0.86 -> 0.79) while being
perfect on symbols. Gating it on query shape is the next obvious step.

## Step 3 — the reranker regression was a misconfiguration (2026-08-06)

It was never a property of the model. `serving_reranker/0` was compiled with
`sequence_length: 128`, which truncates the query/document pair to roughly 400
characters. A symbol query survives that because the identifier sits in the
header `rerank_text/1` prepends; a conceptual answer usually sits deeper in the
chunk and was simply never seen.

Two things I had concluded were wrong. "The truncation theory is dead" was based
on the **mean** chunk size (243 bytes) when the distribution is what mattered —
p50=129, p90=579, p99=1532 — and the failing targets were all at the top end
(exqlite `journal_mode` 953-1547b, boruta PKCE 1148-1223b). And "gate the
reranker on query shape" was unnecessary: nothing needed gating, one number
needed changing.

Score extraction was verified correct first — `[%{score: 8.64}, %{score: -11.29}]`,
one logit per pair, order preserved when the input is reversed.

### sequence_length sweep (batch 20, 40 candidates)

| seq_len | all r@5 | all MRR | concept r@5 | concept MRR | ms |
| --- | --- | --- | --- | --- | --- |
| 128 | 0.88 | 0.73 | 0.79 | 0.50 | 330 |
| 256 | 0.88 | 0.77 | 0.79 | 0.57 | 602 |
| 384 | 0.92 | 0.78 | 0.86 | 0.60 | 976 |
| 512 | 0.96 | 0.81 | 0.93 | 0.64 | 1419 |

No knee — quality rises monotonically to 512, the model's ceiling. Note that at
128 and 256 reranking was **worse than not reranking** (hybrid scores 0.92), so
the stage was actively harmful for its entire life before this.

### Depth: less is more

| per-arm depth | rerank pool | r@5 | MRR | cand | ms |
| --- | --- | --- | --- | --- | --- |
| 10 | 10 | **1.00** | **0.82** | 1.00 | 393 |
| 15 | 10 | **1.00** | **0.82** | 1.00 | 393 |
| 20 | 10 | 0.96 | 0.78 | 0.96 | 395 |
| 40 | 10 | 0.96 | 0.78 | 0.96 | 407 |
| 40 | 40 | 0.96 | 0.81 | 1.00 | 1419 |

Deeper retrieval is **worse**, which is not obvious. RRF scores consensus: an
item ranked ~15 by both arms contributes `1/75 + 1/75 = 0.0267` and outscores one
ranked 3 by a single arm at `1/63 = 0.0159`. With 40-deep arms there are enough
mediocre-but-agreed items to push a strong single-arm hit out of the fused top
10. Shallow arms remove them.

This is also what finally justifies RRF. At depth 40 it looked pointless — tied
hybrid on recall, ranked worse. At depth 10 feeding a correctly configured
reranker, RRF's `cand` is 1.00 where hybrid's is 0.92: the union is what
guarantees the answer is in a pool small enough for the cross-encoder to sort
well. All three stages are needed, and only in this configuration.

### Reranker model comparison

`Bumblebee.Text.cross_encoding` needs an architecture Bumblebee implements with a
sequence-classification head, which excludes most current rerankers:

| model | loads | note |
| --- | --- | --- |
| `cross-encoder/ms-marco-MiniLM-L-6-v2` | yes | Bert, 22M |
| `cross-encoder/ms-marco-MiniLM-L-12-v2` | yes | Bert, 33M |
| `BAAI/bge-reranker-base` | yes | Roberta, 278M |
| `mixedbread-ai/mxbai-rerank-xsmall-v1` | no | `DebertaV2ForSequenceClassification` unsupported |
| `jinaai/jina-reranker-v2-base-multilingual` | no | see below |

Measured on the same 26 queries at seq 512, arms 15, rerank top 10:

| model | params | r@5 | MRR | concept MRR | symbol MRR | ms |
| --- | --- | --- | --- | --- | --- | --- |
| **MiniLM-L-6** | 22M | **1.00** | **0.82** | **0.66** | **1.00** | **395** |
| MiniLM-L-12 | 33M | 0.92 | 0.79 | 0.61 | 1.00 | 759 |
| bge-reranker-base | 278M | 1.00 | 0.78 | 0.62 | 0.96 | 1917 |

The smallest model wins on every axis. Capacity is not the constraint on this
task — configuration was, and recall@5 is now saturated, so a stronger reranker
has nothing left to win here. Selectable via `AI_RERANK_MODEL` if that changes.

> **Superseded by Step 12.** These three were measured on 26 queries and a
> 2755-row corpus. Step 12 sweeps six models on the corrected 28-query set at
> 3967 rows and reaches a different default.

**Why jina fails specifically.** `Bumblebee.load_spec/1` succeeds and returns
`Bumblebee.Text.Roberta{architecture: :for_sequence_classification}` — the
architecture is fine. The weights are not: jina ships flash-attention parameter
names (`roberta.encoder.layers.N.mlp.fc1`, `.mixer.out_proj`, `.norm1`,
`roberta.emb_ln`) where Bumblebee's Roberta mapping expects the stock HuggingFace
layout (`encoder.layer.N.intermediate.dense`, `.attention.output.dense`,
`embeddings.LayerNorm`). It is structurally XLM-RoBERTa under a different key
layout, so a remapping loader is possible — but the two larger models that *do*
load both scored worse, so there is no reason to expect it to pay.

### Final configuration and control

> **Superseded.** `MiniLM-L-6-v2` is no longer the default and nothing is loaded
> unless `AI_RERANK_MODEL` is set. The claim that "all three stages are needed"
> held only while `limit` was 5; at 10 the reranker cannot change what is
> returned.

`sequence_length: 512`, `batch_size: 10`, `AI_RERANK_MODEL` defaulting to
`ms-marco-MiniLM-L-6-v2`; retrieval 15 per arm, RRF, rerank top 10.

```
26 queries · top-5 · 15 per arm · rerank top 10

all           recall@5   MRR@10      cand        ms
fts                 0.92      0.67      0.96         2
vector              0.85      0.73      0.96        29
hybrid              0.88      0.78      0.92        29
rrf                 0.88      0.77      1.00        27
rrf+rerank          1.00      0.82      1.00       395

concept (14)  recall@5   MRR@10      cand        ms
rrf+rerank          1.00      0.67      1.00       415

symbol (12)   recall@5   MRR@10      cand        ms
rrf+rerank          1.00      1.00      1.00       391
```

Every query in the set now has its answer in the top 5. recall@5 is saturated;
**MRR@10 (0.82, concept 0.67) is the only headline left with room**, and further
work has to be judged on it. The set needs harder queries before it can measure
anything else.

## Step 4 — wired into the server (2026-08-06)

`Docs.Search.run_query/4` no longer intersects. The pipeline is now:

```
query ─┬─ QuerySanitizer ─→ FTS5 BM25   ─→ top 15 ┐
       └─ embed API      ─→ sqlite-vec  ─→ top 15 ┴─→ Fusion.rrf ─→ top 10
                                                        └─→ Reranker ─→ top N
```

Both arms join `base_query`, so the package/version/examples scoping applies
*before* the depth cut — ranking the FTS table alone and filtering afterwards
would spend the whole 15-item budget on other packages.

Two modules are shared with the eval harness, for the same reason
`QuerySanitizer` already was: `Docs.Fusion` and `Docs.Reranker`. The harness
keeps its own arm implementations, because it has to measure strategies the
server does not implement (`hybrid` is the intersection RRF replaced, kept as the
control), but the two stages that *are* production must not be reimplemented
there or those rows stop describing the server.

Degradation paths, all exercised:

| condition | behaviour |
| --- | --- |
| no embedding (no API key, or model mismatch) | FTS-only, ranked by BM25 |
| reranker serving absent or output unrecognised | fused RRF order, logged |
| keyword arm matches nothing | vector arm alone carries the fusion |
| both arms empty | `{[], []}` — not an error |

Verified end to end through `Docs.Search.search/2`: `"Building a Server"` returns
the guide at rank 1 with 3 of 4 results from that page; the PKCE query returns
`Boruta.Oauth.Client.t/0` at rank 1; `Req.merge/2` at rank 1; a nonsense query
returns vector-nearest rows rather than raising.

**`embed_text/1` now de-duplicates its fields**, which is what the re-index was
for. A moduledoc has `module` and `signature` both set to the module name, so the
identifier was embedded twice with nothing to balance it on the 32% of rows
holding under 60 bytes of content.

### Control after wiring — 26 queries

```
26 queries · top-5 · 15 per arm · rerank top 10

all           recall@5   MRR@10      cand        ms
fts                 0.92      0.67      0.96         3
vector              0.85      0.72      0.96        36
hybrid              0.88      0.75      0.92        31
rrf                 0.88      0.73      1.00        27
rrf+rerank          1.00      0.82      1.00       396

concept (14)  recall@5   MRR@10      cand        ms
rrf+rerank          1.00      0.66      1.00       411

symbol (12)   recall@5   MRR@10      cand        ms
rrf+rerank          1.00      1.00      1.00       390
```

`hybrid` is retained in the table only as the control — it is what the server ran
before this step (0.88/0.75) and is no longer reachable in production.

### Live MCP verification (2026-08-06)

Everything above was measured in the dev BEAM. Run against the real server —
`MIX_ENV=prod mix mcp.server --no-compile`, through the Anubis stdio transport:

- `list_indexed_packages` reports the new block:
  `embedding: {index_model: "mistral-embed", dims: 1024, query_model:
  "mistral-embed", matches_config?: true}`.
- `"Building a Server"` / anubis_mcp — the guide at rank 1, five of the top seven
  from `building-a-server.html`, no navigation chunks.
- `Req.merge/2` / req — exact hit at rank 1, its examples at 4.
- boruta returns the pre-release notice correctly.
- **Auto-ingest end to end**: `nimble_options` was not indexed; one
  `search_docs` call downloaded, chunked, embedded and answered inside the
  request — 53 docs, no timeout notice, rank 1 the right section. Invariants
  held: 1024 dims, 0 unembedded, 0 navigation chunks, 0 backslash escapes,
  `embedding_config` unchanged.

**The live call disagreed with the eval, and the eval was wrong.** The PKCE query
scored a perfect rank-1 hit while the server returned `Boruta.Oauth.Client.t/0` —
a typespec listing `pkce: boolean()` among thirty fields — and put the actual
guide at rank 8. `{:content, "PKCE"}` matched 7 rows across 6 modules including a
changelog entry. Tightened to `{:module, "pkce"}`, which is the guide's own page.

That single change exposed a genuine reranker failure the loose expectation had
been hiding:

```
[boruta] prevent interception…   fts 5   vector 1   hybrid 1   rrf 1   rerank 8
```

Retrieval puts the guide at rank 1 on three arms. **The cross-encoder demotes it
to 8**, preferring the typespec — which shares "authorization code", "public
client" and "pkce" as literal tokens while explaining none of them. This is the
same weakness as the earlier concept regression, surviving at seq 512.

### Control after tightening — 26 queries

```
all           recall@5   MRR@10      cand        ms
fts                 0.92      0.67      0.96         3
vector              0.88      0.76      1.00        40
hybrid              0.92      0.79      0.96        31
rrf                 0.92      0.76      1.00        28
rrf+rerank          0.96      0.78      1.00       397

concept (14)  recall@5   MRR@10      cand        ms
vector              0.86      0.69      1.00        53
hybrid              0.86      0.73      0.93        33
rrf                 0.86      0.64      1.00        28
rrf+rerank          0.93      0.59      1.00       405

symbol (12)   recall@5   MRR@10      cand        ms
rrf+rerank          1.00      1.00      1.00       391
```

Honest reading, now that the metric is not being flattered:

- The reranker **raises concept recall** (0.86 -> 0.93) and **lowers concept MRR**
  (rrf 0.64, hybrid 0.73, reranked 0.59). It pulls answers into the top 5 that
  retrieval missed, and pushes rank-1 answers down. Both effects are real.
- On symbols it remains perfect and unambiguous.
- recall@5 is no longer saturated (0.96), so the set can measure again.

> **Superseded** — `limit` is 10 again, with the reranker off. The observation
> below is still true and is the cost being accepted: ranks 6-10 are RRF's and
> nothing ranks them.

`search_docs` now returns `limit: 5` rather than 10. The rerank pool is 10, so
returning all of it handed back exactly the tail the cross-encoder had just
demoted — measured live, the last two or three rows of every search were
changelog entries and unrelated functions.

## Step 5 — bounding the reranker's authority (2026-08-06)

> Still current *when the reranker is enabled* — `fused` remains the strategy.
> The audit in Step 7 shows the supporting measurement is one query wide.

The PKCE query survived every fix so far: three retrieval arms put the guide at
rank 1, the cross-encoder dropped it to 8, and with `limit: 5` it stopped being
returned at all.

**Hypothesis tested and rejected: chunk labelling.** `Reranker.text/1` prepends a
header, and `signature` — the field carrying the heading trail — was not in it.
Scored four header variants against the same candidate pool:

| header | pkce guide rank |
| --- | --- |
| `module.function` (current) | 8 |
| `signature` only | 8 |
| `module` + `signature` | 8 |
| no header at all | 10 |

Labelling moves nothing. It did surface a real defect — `function` is already
module-qualified on modern ExDoc, so the header read
`Boruta.Oauth.Client.Boruta.Oauth.Client.public?/1`, the module name twice. Fixed;
it wastes tokens at the compiled sequence length but was not the cause.

**The actual cause.** Every score in that pool is negative (best −2.58): the model
is saying nothing here answers the question, and it is *right*. boruta's PKCE
guide is a how-to —

```
45742   26b  "# Notes for pkce extension"
45743  575b  "…create a client with pkce value as true"
45744  503b  "…sending the code_challenge and code_challenge_method…"
```

— that never explains why PKCE exists, never says "interception", never says
"public client". No chunk answers the question in those words.

But the **bi-encoder bridged the gap anyway** and put the guide at rank 1, while
the cross-encoder, judging the pair on its literal text, preferred
`Boruta.Oauth.Client.t/0` — a typespec listing `pkce: boolean()` among thirty
fields. So this is not a labelling problem or a model-quality problem. It is a
question of how much authority the last stage gets.

### Strategy comparison (same corpus, 26 queries)

| strategy | all r@5 | all MRR | concept r@5 | pkce rank |
| --- | --- | --- | --- | --- |
| `pure` — cross-encoder ordering wins | 0.92 | 0.78 | 0.86 | 8 |
| `gated` — keep retrieval order if best score < 0 | 0.92 | 0.77 | 0.86 | 8 |
| **`fused`** — RRF of retrieval order with reranked order | **0.96** | **0.78** | **0.93** | **3** |

`fused` is now the default (`AI_RERANK_STRATEGY` to override). No latency cost —
a second fusion over ten ids.

**But see the audit below: this table does not support the choice.** The whole
aggregate difference is the one query the strategy was selected on.

`gated` was the more elegant idea and does nothing: the all-negative condition
either does not fire or the retrieval order is not better when it does.

## The eval is not comparable across ingests

Found by accident, and it invalidates any before/after that spans an ingestion.
The live `nimble_options` test added 53 rows, and with nothing else changed:

```
                before ingest    after ingest
fts             0.92  0.67   →   0.88  0.67     ← moved
vector          0.88  0.76   →   0.88  0.76       identical
hybrid          0.92  0.79   →   0.92  0.79       identical
```

**BM25 is collection-global.** FTS5's `bm25()` uses corpus-wide document
frequency and average document length, so indexing any package shifts the keyword
ranking of queries in *other* packages. Vector search is immune — cosine is
per-row.

Three consecutive runs of an identical configuration give identical numbers, so
this is not noise; it is a real dependency on corpus composition. The report now
prints a corpus fingerprint (`corpus 10 packages / 2755 rows`) so a comparison
against a table built on a different corpus is visible rather than silently
wrong. The step-by-step comparisons above all held the corpus fixed and stand.

### Control — 26 queries, corpus 10 packages / 2755 rows

```
all           recall@5   MRR@10      cand        ms
fts                 0.88      0.67      0.96         3
vector              0.88      0.76      1.00        32
hybrid              0.92      0.79      0.96        31
rrf                 0.92      0.76      1.00        28
rrf+rerank          0.96      0.79      1.00       398

concept (14)  recall@5   MRR@10      cand        ms
rrf+rerank          0.93      0.60      1.00       413

symbol (12)   recall@5   MRR@10      cand        ms
rrf+rerank          1.00      1.00      1.00       390
```

Concept MRR (0.60) remains the weakest number and the reranker is still what
holds it down — it raises concept recall (0.86 -> 0.93) while ranking worse than
plain retrieval (hybrid 0.73). Bounding its authority recovered the recall; the
ordering gap is the next thing worth attacking.

## Step 6 — the RRF `k` sweep, a null result (2026-08-06)

Reasoning that motivated it: the second fusion combines two permutations of the
*same* ten items, so `k` stops being a smoothing constant and becomes the dial
controlling how much authority the cross-encoder has. The score spread confirms
that much —

| k | best/worst score ratio over 10 items |
| --- | --- |
| 0 | 10.00x |
| 10 | 1.82x |
| 60 | 1.15x |

At 60 every score sits within 15% of every other, which looks like an
accidentally extreme setting: 60 comes from the RRF paper, where the task is
fusing large candidate sets from independent systems.

**It moves nothing.**

| k | all r@5 / MRR | concept r@5 / MRR | symbol |
| --- | --- | --- | --- |
| 0 | 0.96 / 0.78 | 0.93 / 0.60 | 1.00 / 1.00 |
| 5 | 0.96 / 0.79 | 0.93 / 0.60 | 1.00 / 1.00 |
| 10 | 0.96 / 0.79 | 0.93 / 0.60 | 1.00 / 1.00 |
| 20 | 0.96 / 0.79 | 0.93 / 0.60 | 1.00 / 1.00 |
| 60 | 0.96 / 0.79 | 0.93 / 0.60 | 1.00 / 1.00 |

Per-query, five of 26 shift by exactly one rank between k=0 and k=60 — three
improve, two worsen. Noise, not a gradient.

The explanation, which is only obvious afterwards: over ten items, ordering by
`Σ 1/(k+rᵢ)` approximates ordering by **rank-sum** at large k and weights the
head at k=0, and those two orderings disagree only when an item is extreme on one
list and middling on the other. Rare enough here to vanish into noise.

**What mattered was the binary, not the weighting.** Whether retrieval's order
gets a vote at all took recall@5 from 0.92 (`pure`) to 0.96 (`fused`). How
heavily it votes is irrelevant. The knob was removed and the null result recorded
in `Reranker.fusion_k/0` so nobody re-runs the experiment.

### Where this leaves concept MRR

0.60, and still the weakest number. Worth stating plainly what is now known about
it:

- Plain retrieval orders concept queries **better** than the reranked pipeline
  (hybrid 0.73, rrf 0.64, reranked 0.60) while finding fewer of them
  (recall 0.86 against 0.93).
- So the cross-encoder is trading ordering for recall on exactly the query class
  it was added to help, and bounding its authority recovered the recall without
  recovering the ordering.
- That is not surprising given the model: an MS MARCO cross-encoder is out of
  domain on Elixir documentation, while the embedding model is code-tuned.
  Capacity does not fix it — the two larger rerankers that load both scored worse.

The honest next step is **not** another knob. Fourteen concept queries cannot
distinguish 0.60 from 0.73 with any confidence — the whole gap is roughly seven
one-rank movements. The set needs to be perhaps three times larger, with
expectations tightened the way the PKCE one was, before any further tuning here
means anything.

## Step 7 — auditing the `fused` decision (2026-08-06)

Prompted by a fair objection: fusing a permutation of a set with the set itself
looks like it should not do much, so the reported gain deserves scrutiny.

**What the second fusion actually is.** Both inputs hold the same ten documents,
so each contributes `1/(60 + rank)` exactly twice, and with k=60 that term is
nearly linear in rank. The result therefore orders by something very close to
`retrieval_rank + reranker_rank`. It is **rank averaging** — Borda count — and
nothing more. Calling it "bounded rerank" made it sound like a mechanism when it
is an ensemble.

**Per-query audit, pure vs fused, same corpus:**

```
improved                          pure → fused
  [req] retry                        4 → 3
  [req] HTTP stub                    2 → 1
  [anubis] declare a tool            4 → 3
  [lazy_html] visible text           4 → 3
  [boruta] PKCE                      8 → 2   <- +6

worsened
  [req] redirects                    1 → 2
  [exqlite] WAL                      3 → 4
  [anubis] error result              5 → 6
  [gen_magic] file type              1 → 2

9 of 26 differ · 5 up, 4 down · every movement ±1 except PKCE
```

**Remove PKCE and the effect is exactly zero** — four up by one, four down by
one. The entire aggregate difference is the single query the strategy was chosen
on after watching it fail, which is post-hoc fitting. And the size of that
difference (recall@5 0.92 -> 0.96, one query) is 0.04, against a standard error
at n=26 of `sqrt(0.95 * 0.05 / 26)` = **0.043**. Exactly one standard error.
Indistinguishable from nothing.

`fused` is kept, but on the **mechanistic** argument and not the measurement: a
bi-encoder and a cross-encoder fail differently, so averaging their ranks is the
standard response to two rankers with uncorrelated errors, and the PKCE case
demonstrates that mechanism rather than merely being a lucky draw. Recorded as
unvalidated.

The shape of the audit is itself evidence against the ensemble argument, though:
eight queries moving by exactly one rank and one moving by six reads as "the two
rankers agree except in one case", which is the regime where averaging buys
nothing. Genuinely uncorrelated errors would show larger, asymmetric movement.

### The pattern behind three of these

`client_credentials`, `PKCE` and now `fused` — three times a conclusion rested on
one query, and all three were caught by reading output rather than by reading the
metric. At n=26 a single query is 0.04, which is the size of every "improvement"
claimed in this document below the tokenizer sweep.

What still stands, because it is larger than one query:

- the tokenizer/sanitiser work (0.80 -> 0.88 on `fts`, four queries)
- `sequence_length` 128 -> 512 (0.79 -> 0.93 concept recall, two queries, and
  monotone across four values rather than a single jump)
- the `k` sweep as a **null** result (nulls are robust at any n; they only need
  the absence of an effect)

What does not, and should be re-tested before being trusted: `pure` vs `fused`,
and the arm-depth choice of 15 over 10.

## Step 8 — phoenix, the HTML path, and `mix docs.drift` (2026-08-06)

`refresh: true` on `phoenix` through the live tool — the first exercise of both
the large-package path and a tool-triggered refresh. **1212 docs ingested inside a
single call**, no progress notice, and rank 1 was the `routing.html#forward`
section, which is exactly the answer.

Integrity of the result:

```
1212 rows · 0 unembedded · 1191 distinct (98%) · avg 649b · max 1598b (budget 1600)

ExDoc chrome (View Source, Link to this, <span>, &nbsp;)   0
navigation chunks                                          0
backslash escapes                                          0
"end list" comments                                        0
unbalanced code fences                                    12   <- see below
```

**The 12 unbalanced fences are in the source.** Phoenix's own `search_data` ships
exactly 12 items with an odd fence count — the same titles, verified by
downloading and parsing the tarball independently. `SectionChunker` preserved
them faithfully. `sourcepos` for a fenced `CodeBlock` includes the closing fence
(tested), so slicing is correct for well-formed input; malformed input stays
malformed, which is the right default. Consequence: those 12 rows have
`code_snippet: nil`. Deliberately not "fixed" — closing them would mean inventing
text the package never published, forfeiting the byte-identical property the
`sourcepos` rewrite exists to provide.

One row corpus-wide exceeds the 1600 budget, at 1603: `enforce_ceiling` split at
≤1600 and `balance_fences` then appended a closing fence. Benign.

### `mix docs.drift`

Question raised: after a chunker change, which packages actually need
re-ingesting? The reflex is "all of them", and that costs a full re-embed.

`TarballIngestion.dry_run/3` walks the identical path — download, extract, read
the shipped index, resolve content, chunk — and stops before embedding.
`mix docs.drift` compares the result to what is stored:

```
  anubis_mcp        1128 stored   identical
  boruta             506 stored   identical
  …
  phoenix           1191 stored   identical

Every package matches what today's code produces. A refresh is a no-op.
```

It compares **text only**. A change to `embed_text/1` or to the embedding model
is invisible to it and still needs `mix docs.reindex`.

This also corrected a claim made earlier in this session. The ingest-side files
showed mtimes *after* the last reindex, which looked like the corpus might be
chunked by three different code versions; `git diff HEAD` being empty was
suggestive but could not see edits made between the reindex and the commit. The
drift check settles it directly.

## Is this better than an exact search on hexdocs.pm?

A fair challenge: the tool's premise is describing a functionality rather than
naming it, and if that fails it offers little over a keyword search anyone can
already run.

Partly true, and worth stating precisely.

**On symbol queries it is near-parity.** `fts` alone scores recall@5 **1.00** and
MRR 0.88; the full pipeline reaches 1.00 / 1.00. Paste an identifier and the
keyword arm finds it — hexdocs.pm's own search is the same class of thing. The
reranker buys ordering, not answers.

**The whole product is the concept half.** On 16 conceptual queries, same corpus:

| arm | recall@5 | MRR |
| --- | --- | --- |
| `fts` alone | 0.75 | 0.49 |
| `vector` alone | 0.81 | 0.67 |
| full pipeline | **0.94** | 0.64 |

+0.19 recall over keyword search — about 2.1 standard errors at n=16, which makes
it the second-largest effect measured in this document and one of only three
above the noise floor. Named individually, the queries the keyword arm cannot
reach:

```
[boruta]     prevent interception of the authorization code    fts ·   → 4
[lazy_html]  get the visible text out of a parsed document     fts 6   → 2
[anubis_mcp] server requests a completion from the client      fts 10  → 2
```

And the reverse set — queries FTS finds that the pipeline loses — is **empty**.

**The honest limits.** Concept MRR is 0.64: the answer is usually at rank 2 or 3
rather than 1, so the caller still reads several results. And the tool cannot
answer what the documentation does not say — boruta never explains *why* PKCE
exists, so no retrieval strategy will produce that explanation. Several apparent
retrieval failures in this document were exactly that, misfiled as ranking
problems.

Every live search run this session — `Building a Server`, `Req.merge/2`, sampling,
capability checking, nimble_options schemas, phoenix `forward` — returned a usable
answer at rank 1 or 2. The single live miss was the PKCE question, against a
package that does not document the concept.

## Step 9 — judgements replace expectations (2026-08-06)

The complaint that produced this: for `avoid database is locked errors under
concurrent writes`, the harness marked rows 1 and 3 and left row 2 unmarked —
`Transaction mode`, which says to set `default_transaction_mode: :immediate`.
That is the actual remedy for lock contention: a `DEFERRED` transaction takes the
write lock lazily, so a read-then-write must upgrade it, and a failed upgrade is
`SQLITE_BUSY` that cannot be safely retried. `IMMEDIATE` takes the lock at
`BEGIN`.

So the unmarked row was a **correct answer the expectation could not see**. Read
from the scoring side it was being counted as a false positive; read from the
labelling side it was a false negative. Same disagreement, and the human had the
better evidence.

**What `✓` actually meant.** "Matches the substring chosen in advance" — not "is
a good answer". A single-target expectation marks at most one row, while a good
result set is usually several rows. Every number in this document below the
tokenizer sweep is therefore a *floor* on answer quality that was reported as
though it described it. Judged properly, that query returns 4 useful rows of 5;
the expectation reported "hit at rank 1" and would have reported the same had the
other four been garbage.

It also explains the four bad expectations (`client_credentials`, `PKCE`, the
shortened sampling pair, `declare a tool`) as structural rather than accidental:
encoding "good answer" as a substring match fails this way by construction.

### The replacement

- `StdioMcp.Docs.Judgements` — a human-editable file, `priv/eval/judgements.md`.
  Keyed on **`{package, hexdocs_url}`**, because row ids die on every re-ingest
  and content hashes die on every re-chunk, while the URL identifies the section
  a reader would open. Chunks sharing a URL are collapsed — one document, one
  judgement.
- `mix docs.judge` — runs every query through **`Docs.Search.search/2`**, the
  production path, and writes what it returned for marking. Existing marks are
  preserved on regeneration.
- `mix docs.eval --judged` — scores `P@k` (what fraction of the returned page is
  useful), `any-relevant`, and `coverage`. Unjudged rows are excluded from both
  numerator and denominator, and `any-relevant` is restricted to queries with at
  least one mark, so a partly-marked file reports honestly on what it knows
  rather than reading as failure.

Demonstration on the single query discussed above, 6 of 215 results marked:

```
judged relevance · rrf+rerank · top 5

all             P@k  0.80   any-relevant  1.00   coverage  0.04
concept (16)    P@k  0.80   any-relevant  1.00   coverage  0.06
```

`P@k 0.80` is four useful rows of five — matching the reading exactly, and a
number the expectations were structurally incapable of producing.

The remaining 209 marks are the actual work, and they are not mine to make: my
judgement standing in for the user's is the failure this replaces.

## Step 10 — source links, and why not GitHub code search (2026-08-06)

ExDoc already writes a per-function "View Source" anchor pointing at the exact
file and line, and for packages that tag their docs it is pinned to the version.
It is in the tarball we download anyway. The HTML walk was **discarding it**:
`icon-action` elements are stripped as chrome, which is right for the anchor text
("View Source" is noise) and wrong for the `href`.

Coverage measured across the corpus:

| package | source links | form |
| --- | --- | --- |
| phoenix | 267 rows | `blob/v1.8.9/lib/phoenix/router.ex#L1428` — version-tagged |
| req | 107 | `blob/v0.7.2/...` — version-tagged |
| boruta | 298 | `blob/master/...` — **not** tagged, can drift from the docs |
| anubis_mcp | 0 | no `source_url` in its docs config |

Stored verbatim, `master` links included: rewriting those to a guessed tag would
invent precision the package did not publish — the same rule that leaves
phoenix's 12 malformed code fences alone.

`mix docs.sources` backfills without embedding. A source link does not affect the
vector, so `mix docs.reindex` would be the wrong instrument — it re-embeds every
document to write one metadata field.

### GitHub code search: tested and rejected

The idea was to reach the implementation for packages that ship no source links.
Measured rather than assumed:

```
code search,   unauthenticated  ->  HTTP 401     token mandatory, always
issues search, unauthenticated  ->  HTTP 200
```

Three reasons it loses:

1. **401 without a token.** `search_github_issues` works today with none; this
   would make `GITHUB_TOKEN` a hard requirement.
2. **~10 requests/minute** even authenticated.
3. **Default branch only** — decisive. It returns `main`, not the tagged version
   the docs describe, which silently breaks the version-pinning every other part
   of this server enforces (one version per package, `embedding_config` refusing
   mismatches, drift notices).

And it only helps the minority case. For those packages the Hex metadata already
carries the repo — `zoedsoupe/anubis-mcp`, free, in a call `HexPackage.fetch/1`
already makes — so handing the repo back lets an agent use its own tools, pick
the right tag, and skip the rate limit.

That leaves a three-tier handoff, strongest first, each free and each degrading
to the next:

```
deps/ on disk       -> grep, authoritative, current
source_url in docs  -> exact file + line + version tag
github repo link    -> the agent's own tools take over        (still to build)
```

## Step 11 — `PROJECT_ROOT` and the version rules (2026-08-06)

The server runs from its own directory, so `:application.get_key/2` reports
*its* dependencies and never the repo being edited. That is why `CLAUDE.md`
carried fifteen lines telling the caller to read `mix.lock` and pass `version`
on every call — a per-call discipline that depends on the model remembering.

Three designs were considered. A `SessionStart` hook injecting the versions
(~750 bytes for 49 deps, but correctness rests on the model using them every
call). An `init` tool pushing the lockfile into session assigns (verified
possible — `Scheduler` writes a tool's returned frame back into session state at
`scheduler.ex:225` — but still needs the model to call it). And simply naming the
path in the server's own `env`, which needs no protocol, no context and no
discipline at all.

The third won. `StdioMcp.Docs.Lockfile` reads `$PROJECT_ROOT/mix.lock` **on every
lookup, never cached**: caching at boot would be marginally faster and wrong,
since `mix deps.get` mid-session would leave the server answering with versions
the project no longer uses. Parsed by regex rather than `Code.eval_string/1` —
nothing here needs to execute a file to read two fields out of it.

### The version rules, finally written down

The confusion was real and had a cause: `PLAN.md` holds **two** policies, for two
different products, and they had merged in memory.

> | | local_hex | the service |
> | scope | whatever your lockfile pins, **any age** | latest stable + pre-releases ahead |

"Do not accept below latest-stable" is the *service's* rule — it exists so a small
VPS does not become a Hex mirror. Locally the requirement is the opposite. So
with a lockfile there is **no version policy to decide**: it is authoritative,
pre-release or not, ancient or not. The RC-versus-stable question only arises
when nothing pins the package.

```
explicit version:            -> that version
$PROJECT_ROOT/mix.lock       -> the locked version, any age, pre-release included
the server's own BEAM        -> that version   (report drift, never switch)
nothing pins it              -> Hex latest stable (report drift, never switch)
```

`app_version` keeps its old report-don't-switch behaviour deliberately: it is an
accident of where the server was launched, not a statement about the caller. The
lockfile *does* switch, because it is such a statement.

**"Never downgrade" was rejected.** If a project genuinely runs `boruta 2.3.0`,
refusing to move back from `3.0.0-beta.4` serves it documentation for code it
does not run — silently. Wrong answers beat slow answers only when you know they
are wrong.

### The two-project problem is not a version problem

One version per package is the invariant, so honouring a second project's
lockfile evicts the first project's docs. A single switch is legitimate. Repeated
switching means two projects share one `DATABASE_PATH` and will re-download and
re-embed on every alternation — which no version policy fixes, because it is a
configuration problem. The switch now emits a notice naming that, since the
symptom otherwise reads as "the tool is slow".

Multi-version storage is deliberately still the *service's* problem
(`PLAN.md` B3: "`save/3` prunes by package + version, not by package as here").

Verified in the unit sense: no `PROJECT_ROOT` degrades to the previous
behaviour; a bad path logs and degrades rather than raising; an edit to
`mix.lock` is picked up on the next lookup without a restart.

Verified live, round-trip, through the real MCP server — the switch path is the
one that *evicts* data, so it was worth spending two ingests of a 54-document
package rather than reasoning about it:

```
PROJECT_ROOT -> test_lock/mix.lock pinning 1.1.0
  "Replaced indexed 'nimble_options' v1.1.1 with v1.1.0, which …/test_lock/mix.lock pins…"
  54 docs · every result version 1.1.0 · source_url blob/v1.1.0/…

PROJECT_ROOT -> the repo, whose mix.lock pins 1.1.1
  "Replaced indexed 'nimble_options' v1.1.0 with v1.1.1, which …/mix.lock pins…"
  53 docs · every result version 1.1.1 · source_url blob/v1.1.1/…
```

The differing document counts (54 against 53) are the useful detail: the two
ingests really did fetch different tarballs. `source_url` tracked the version in
both directions, which it must — a link pointing at a different version than the
documentation beside it would be a quiet correctness bug. One version present
throughout, `embedding_config` untouched.

### Repeated mistake worth naming

`Reranker.rerank/2` was first written query-first and piped as
`docs |> Reranker.rerank(query)`, which binds the arguments backwards and blew up
on the first run. That is the *second* occurrence of exactly this bug —
`SectionChunker.prepend_heading/2` had it and silently returned `[]`, dropping
every oversized section. The rule that would have prevented both: **the value
being transformed goes first**, so the function pipes the way it reads. Both
signatures now follow it.

## Step 12 — the reranker sweep (2026-08-07)

> **Superseded.** This picked `MiniLM-L4-v2` as the *default*. The reranker is
> now off by default and L4 is the opt-in; and every number here predates the
> `signature`-aware reranker, which moved reranked MRR 0.78 → 0.81 on its own.

Prompted by switching the live server to `bge-reranker-base` and finding it
visibly better on one query while feeling much slower.

**The repo ids in circulation are wrong.** HuggingFace renamed these: the
canonical form dropped the dash before the layer count.

```
cross-encoder/ms-marco-MiniLM-L-6-v2   ->  ms-marco-MiniLM-L6-v2
cross-encoder/ms-marco-TinyBERT-L-2-v2 ->  ms-marco-TinyBERT-L2-v2
cross-encoder/ms-marco-TinyBERT-L-4    ->  ms-marco-TinyBERT-L4
```

The old forms still redirect, so the previous default kept working. But
`ms-marco-TinyBERT-L-4-v2` — which appears in several model lists — does not
exist in either scheme and fails to load: the `-v2` suffix belongs to the L2
line, not L4.

### Six models, 28 queries, corpus 11 packages / 3967 rows

| model | params | all r@5 | all MRR | concept r@5 | concept MRR | symbol | ms |
| --- | --- | --- | --- | --- | --- | --- | --- |
| TinyBERT-L2-v2 | 4M | 0.93 | 0.78 | 0.88 | 0.62 | 1.00 / 1.00 | **55** |
| TinyBERT-L4 | 14M | 0.93 | 0.79 | 0.88 | 0.63 | 1.00 / 1.00 | 229 |
| TinyBERT-L6 | 22M | 0.96 | 0.73 | 0.94 | 0.61 | 1.00 / **0.90** | 1017 |
| **MiniLM-L4-v2** | 19M | **0.96** | **0.80** | **0.94** | **0.66** | 1.00 / 1.00 | **279** |
| MiniLM-L6-v2 | 22M | 0.96 | 0.80 | 0.94 | 0.65 | 1.00 / 1.00 | 403 |
| MiniLM-L12-v2 | 33M | 0.93 | 0.81 | 0.88 | 0.66 | 1.00 / 1.00 | 772 |
| bge-reranker-base | 278M | 0.93 | 0.78 | 0.88 | 0.61 | 1.00 / 1.00 | 1930 |

**Capacity is not the axis.** Sorted by parameters the quality column does not
move: 4M and 278M both score 0.93/0.78 while 19M and 22M lead. A **70x** span in
size produces a 0.03 spread in recall@5 — one query — against a **35x** span in
latency. Read strictly the table says all seven are equivalent on quality and
differ enormously in speed, so take the fast one.

`MiniLM-L4-v2` is the new default: it matches L6 on every quality number at a
third less latency. That is a latency argument, not a quality one. `TinyBERT-L6`
is the one to avoid — 0.90 symbol MRR, the only model that fails the case every
other one gets perfect.

### The property recall@5 cannot see

The observation that started this was real, and the aggregate is blind to it. On
`"Building a Server"` against anubis_mcp, every model puts the guide at rank 1 —
so recall@5 is 1.00 for all of them — but they differ in whether the *sibling*
page leaks into the top five:

| model | `building-a-client` rank | off-page rows in top 5 | ms |
| --- | --- | --- | --- |
| TinyBERT-L2-v2 | 2 | 2 | 123 |
| MiniLM-L4-v2 | 2 | 1 | 343 |
| MiniLM-L6-v2 | 3 | 1 | 472 |
| MiniLM-L12-v2 | 4 | 1 | 852 |
| bge-reranker-base | **absent** | **0** | 1994 |

Monotone in capacity, and only bge removes it. TinyBERT-L2's second intruder is
`Anubis.Server.Response.completion/0` — "Start building a completion response",
the pure BM25 artefact that shares only `building` and `a` — so the weakest model
admits the noise the others reject.

**But "better" is doing work there.** `building-a-client.html` is not junk: for a
query reading *"Building a Server"*, the guide covering the other half of the
same protocol is defensible, and a reader might want it. `completion/0` is noise;
the client guide is a judgement call. So the axis these models differ on is not
accuracy but **how aggressively they reject topically-adjacent documents**, and
whether strict is right is a preference rather than a measurement.

Two things follow. Capacity buys strictness, not correctness — which is why bge
wins the eye test and loses the aggregate. And `recall@5` asks "did the expected
document appear", never "was the rest of the page any good", which is exactly the
gap `mix docs.eval --judged` and `P@k` exist to close. That file is still at 6 of
215 marks, so the question the eye is asking remains unanswered by any number
here.

---

# Execute commands in an IEX sesion

## Start the app in an IEX session

```sh
AI_API_KEY="xxx" \
iex -S mix run -e "Application.ensure_all_started(:stdio_mcp);"
```

## Search

```sh
StdioMcp.Docs.Search.search("Oauth", package: "anubis_mcp");
StdioMcp.Docs.Search.search("Building a Server", package: "anubis_mcp", refresh: true);
```

```sh
StdioMcp.Docs.TarballIngestion.ingest("anubis_mcp", "1.14.0")
```

## List packages

```sh
{:reply, resp, _} = StdioMcp.Tools.ListIndexedPackages.execute(%{check_hex: true}, Anubis.Server.Frame.new());


resp.content |> hd() |> Map.get("text") |> Jason.decode!();
```

## Get token usage

```sh
{:reply, resp, _} = StdioMcp.Tools.GetTokenUsage.execute(%{}, Anubis.Server.Frame.new());
resp.content |> hd() |> Map.get("text") |> Jason.decode!();
```

## Reranking

```elixir
query = "How many people live in Berlin?"

candidates = [
  "Berlin has a population of 3.5 million.",
  "The city of Berlin has a few million inhabitants.",
  "Paris, with 2 millions inhabitants, is less populated than Berlin.",
  "Berlin is the capital and largest city of Germany by both area and population.",
  "Ecto changesets allow parameters to be cast and validated."
]

input_batch = Enum.map(candidates, fn doc -> {query, doc} end)

# 2. Pass the entire list to Nx.Serving.run/2 (or batched_run/2)
{time_us, results} = :timer.tc(fn ->
  Nx.Serving.batched_run(Rerank, input_batch)
end)
```

## Check tools via a client

In another terminal:

```sh
> iex -S mix

{:ok, _} =
  Anubis.Client.Supervisor.start_link(
    name: MyMCPClient,
    transport: {:stdio, command: "/opt/homebrew/bin/mix", args: ["mcp.server", "--no-compile"]},
    client_info: %{"name" => "cli"}
  )

{:ok, tools} = Anubis.Client.list_tools(MyMCPClient)
IO.inspect(tools)
{:ok, result} = Anubis.Client.call_tool(MyMCPClient, "list_indexed_packages", %{"check_hex" => true})
IO.inspect(result)
```

## Query a Mistral endpoint

Ex: <https://docs.mistral.ai/api/endpoint/embeddings>

```sh
curl https://api.mistral.ai/v1/embeddings \
 -X POST \
 -H 'Authorization: Bearer xxx' \
 -H 'Content-Type: application/json' \
 -d '{
  "input": "Your value",
  "model": "codestral-embed"
}'
```

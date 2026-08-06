# Retrieval eval baseline — 2026-08-06

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

`search_docs` now returns `limit: 5` rather than 10. The rerank pool is 10, so
returning all of it handed back exactly the tail the cross-encoder had just
demoted — measured live, the last two or three rows of every search were
changelog entries and unrelated functions.

## Step 5 — bounding the reranker's authority (2026-08-06)

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

### Repeated mistake worth naming

`Reranker.rerank/2` was first written query-first and piped as
`docs |> Reranker.rerank(query)`, which binds the arguments backwards and blew up
on the first run. That is the *second* occurrence of exactly this bug —
`SectionChunker.prepend_heading/2` had it and silently returned `[]`, dropping
every oversized section. The rule that would have prevented both: **the value
being transformed goes first**, so the function pipes the way it reads. Both
signatures now follow it.

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

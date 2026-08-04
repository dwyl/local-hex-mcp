# Plan: GitHub↔Hex linking, and porting to hex_gh

Written 2026-08-04, after the extraction/ingestion rework in local_hex_mcp.
Two independent tracks. Track A is new work, done here first. Track B is the
port. They do not block each other.

---

## Track A — link GitHub issues to Hex packages

Do this in `local_hex_mcp` (stdio, no deploy, fast loop), then it ports with the
rest.

### A0. Hex already knows the repo — take it for free

`GET hex.pm/api/packages/:name` returns `meta.links` containing a GitHub URL for
every package checked. The key casing is inconsistent (`"GitHub"` and
`"github"` both occur), so scan case-insensitively for a `github.com` value.

Measured, and note none of these are guessable from the package name:

| package | repo |
| --- | --- |
| `boruta` | `malach-it/boruta_auth` |
| `text_chunker` | `revelrylabs/text_chunker_ex` |
| `anubis_mcp` | `zoedsoupe/anubis-mcp` |
| `gen_magic` | `evadne/gen_magic` |

Change: add `github_url` to `%HexPackage{}` and parse it. One field, one line of
parsing, no extra request — `HexPackage.fetch/1` already makes this call for
version resolution.

### A1. `search_github_issues` takes `package:` instead of `org:`

Today the tool requires `org:`, which the caller is least likely to know, and
which is the wrong granularity: `org:phoenixframework` sweeps in
`phoenix_live_view`, `phoenix_ecto` and everything else in the org.

- accept `package:` (resolved via A0 to `repo:owner/name`) — this becomes the
  normal path
- keep `org:` as an escape hatch for repos that are not Hex packages
- require at least one of the two

Payoff beyond ergonomics: one identifier (`package`) now works across
`search_docs`, `search_github_issues` and `list_indexed_packages`. Tools that
take different arguments for the same subject do not get chained.

### A2. Carry the fields that answer the actual question

Currently kept: `title, url, state, user, body|>slice(0,300)`.

The question being asked is almost always *"is this a known bug, was it fixed,
and when"*. That needs:

- **`state_reason`** (`completed` / `not_planned` / `reopened`) — `state:
  "closed"` alone is ambiguous, and "closed as not_planned three years ago" is
  the opposite answer to "closed as completed last week"
- **`closed_at`** / `updated_at` — recency is most of the signal
- **`labels`** — often the most compact signal in the payload (`bug`,
  `wontfix`, `upstream`, `needs-repro`)
- **`pull_request`** — the only way to tell a PR from an issue in this
  endpoint's response; required once `is:issue` is dropped
- **longer `body`** — 300 chars is usually the greeting and half a stack trace.
  Everything else in the payload is short; this is the field where more pays.

### A3. `include_prs`

Drop `is:issue` when set. Often the answer to "is this fixed" is an open PR, not
an issue.

### A4. (optional) `since:` from the release date

Hex returns each release's `inserted_at`. "Issues filed since the version I am
running" is a sharper question than "issues ever", and the metadata is already
in hand from the same call. This is the one place where the docs half and the
issues half genuinely compose rather than merely sharing a package name.

---

## Track B — port to hex_gh

`hex_gh` is a Phoenix service on Postgres + pgvector, served over
streamable_http, authenticated with Boruta, running in containers on a VPS. It
holds the *ancestor* of this code: `HexGh.Docs.IngestionWorker` is still the
per-page scraping approach that `TarballIngestion` replaced.

**Not ported:** `Docs.Poller` (confirmed dead), the SQLite/FTS5 query layer
(hex_gh has its own tsvector + pgvector ranking, and a more sophisticated search).

### B0. Fix the hybrid query — independent, do first

`HexGh.Docs.Search.run_query/4` has the same logical bug found and fixed here:

```elixir
where: fragment("... websearch_to_tsquery ...") or
       fragment("... plainto_tsquery ...") or
       not is_nil(d.embedding),          # <- makes both tsqueries irrelevant
order_by: fragment("COALESCE(? <-> ?, 1.0)", d.embedding, ^vec)
```

"FTS matches OR anything embedded" reduces to "anything embedded", so the text
predicates never narrow and the vector ordering scans the whole scoped set.
Unlike sqlite-vec it does not crash — `COALESCE(..., 1.0)` swallows NULL
embeddings — which is why it has gone unnoticed.

Fix: `and` instead of `or`, exclude NULL embeddings from any cosine ordering,
and fall back to vector-only when the keyword terms match nothing. Here this was
both a correctness fix and 94ms -> 53ms on 1288 rows.

No dependency on anything else in this plan. Highest value per hour of the
whole document.

### B1. The storage-agnostic core

These are pure transformations and port nearly verbatim. They are what took
`anubis_mcp` from 903,346 duplicated characters to 9,496:

| what | notes |
| --- | --- |
| tarball acquisition | `repo.hex.pm/docs/{pkg}-{ver}.tar.gz` + `:erl_tar` in memory — replaces the 761-request scrape with one request |
| HTML extraction | LazyHTML tree walk: chrome classes (**both** ExDoc generations), `<pre>` fences, table pipes, `narrow_to_anchor` returning `[]` on a miss |
| markdown extraction | `markdown_section` anchor normalisation (`t:`/`c:` prefix, `/arity` suffix) + identifier-vs-prose matching; `""` on a miss so the HTML path gets a turn |
| chunking | `chunk_size: 1200`, `chunk_overlap: 100`, `balance_fences/1` |
| embedding | `Task.async_stream`, 429 backoff honouring `Retry-After`, **400 token-limit bisection**, `EMBED_PAUSE_MS`, fail-fast abort rather than persisting nil embeddings |
| `HexPackage` | metadata client, `latest_stable` resolution, `published?` validation |
| `RepairBudget` | unchanged |

`lazy_html` moves from `only: :test` to a runtime dependency.

Verification: the distinct-content check. Count rows vs distinct `content`
values, weighted by length. A whole-document fallback inflates row counts while
looking like success — row count alone will not catch it.

### B2. Postgres adaptation

`save/3` prunes and inserts, and must populate `search_vector` (generated column
or trigger, replacing SQLite's `_ai`/`_ad`/`_au` triggers). Small.

### B3. Service architecture — the part that is genuinely different

These are not ports. Local decisions invert on a shared service.

**Version admission — DECIDED: `latest_stable` + pre-releases ahead of it, otherwise refuse and point at local_hex.**

Admit `latest_stable`, plus any pre-release *ahead* of it:

```
keep(v)  <=>  v == latest_stable  or  Version.compare(v, latest_stable) == :gt
```

The same predicate evicts: once `3.0.0` ships, `3.0.0-rc.2` stops being ahead
and is pruned. `Version.compare/2` gives `3.0.0 > 3.0.0-rc.2` for free — no
timer, no cron. Re-evaluate on any request carrying a newer `latest_stable`;
user traffic drives convergence.

Cost is bounded: pre-releases ahead of stable are rare (0 for phoenix, ecto,
req, anubis_mcp; 4 for boruta). What it excludes is the lagging user — phoenix
has 117 stable releases in the current major — and that exclusion is
**deliberate**: a user on phoenix 1.7 has phoenix 1.7 in `deps/`, so `grep` and
local_hex both serve them better. The service's unique value is packages you do
*not* have on disk, and for those latest stable is correct by definition.

Refusal is part of the design, not a gap. It should teach rather than decline —
name what the instance carries and where to get the rest:

> `phoenix 1.7.14` is not indexed here. This service carries the current stable
> (`1.8.9`) plus any pre-release ahead of it. For a version your project pins,
> run the local stdio server against your repo: it fetches the exact tarball for
> your lockfile, and Hex serves every historical version (verified back to
> `phoenix 1.6.16`).

Accepted consequence: when a major ships, the previous stable is pruned. Boruta
stabilising at `3.0.0` removes `2.3.8` — docs for the version most users still
run — at exactly the moment fewest people want `3.x`. Under this policy that is
correct: those users have `boruta 2.3.8` in `deps/` and belong on local_hex. The
service exists for the person *evaluating* `3.0.0`.

This is the boundary that keeps a small VPS from having to become a Hex mirror,
and it is a product split rather than a limitation:

| | local_hex | the service |
| --- | --- | --- |
| scope | whatever your lockfile pins, any age | latest stable + pre-releases ahead |
| storage | your disk, one project | the VPS, all users |
| cost | your API key | yours, for everyone |
| answers | "what does the code I compile against say?" | "what does this library say?" |

**Multi-version storage.** `save/3` prunes by `package + version` (not by
package as here). Two users on different boruta lines must not overwrite each
other.

**`app_version` changes direction.** `:application.get_key/2` on a server
reports the *container's* deps and is wrong for every caller at once. The
concept survives but inverts: the client supplies the version from its
lockfile, and the server answers coverage ("do you have boruta 3.0.0-beta.4?").
`list_indexed_packages` becomes a contract rather than a diagnostic.

**`IngestionJob` becomes a GenServer.** One mailbox gives idempotency by
construction instead of by race resolution. The decisive argument is one that
does not exist locally: the embedding rate limit is a property of the
*service*, not of a request, so `EMBED_CONCURRENCY` must be a service-wide
budget rather than per-job. That needs a queue, which needs a single
coordinator.

Constraint: it must **coordinate, never compute**. Receive request -> check
state -> spawn a supervised Task -> park the caller's `from` and
`GenServer.reply/2` on completion. Ingestion inside the GenServer serialises
every user behind one download. Monitor both sides: jobs so waiters do not hang
on a crash, callers so replies to dead processes are dropped.

(Anubis solves the same problem the same way: `task_waiter :: {from ::
GenServer.from(), request_id}` in `Session.Tasks` is parked callers in a
coordinator's state.)

### B4. Open questions, not yet decided

- **Eviction across packages.** The version policy bounds versions *per package*;
  nothing bounds the number of packages. Needs LRU or age-based eviction.
- **Fairness.** One user ingesting `phoenix` should not starve others. FIFO or
  per-user fair share?
- **Trust boundary.** `package` and `version` arrive from authenticated but
  untrusted clients, and reach a `repo.hex.pm` URL and a filename.
- **Cost attribution.** `get_token_usage` is global here; on a shared service
  embeddings are spent on behalf of a user. Likely where the Prometheus work
  should point.

---

## Suggested order

1. **B0** — hybrid query fix in hex_gh. Independent, immediate, live bug.
2. **A0–A3** — GitHub↔Hex linking in local_hex. Self-contained, fast loop.
3. **B1 + B2** — core pipeline port. The bulk of the value, low risk: mostly
   pure functions with test cases already written here.
4. **B3** — service architecture. Needs the design decisions above settled
   before code.
5. **A4, B4** — refinements once the shape is proven.

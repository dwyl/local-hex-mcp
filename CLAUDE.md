# Local Stdio MCP (`hex_local`) Guidelines

## MCP Tools Reference

- **`search_docs`**: Search official HexDocs guides, typespecs, and code examples.
  - **`package` is required.** Always extract the target package name from the request (e.g. `boruta`, `anubis_mcp`, `phoenix`, `plug`) and pass it as `package`. The server does not read package names out of the query text: a search naming a package only in `query` returns rows from *other* packages that share keywords, indistinguishable from a real answer. Naming an unindexed package is correct — that is what triggers ingestion.
  - **A question spanning several packages is several calls.** Searches are scoped to one package, so decompose and consolidate rather than asking the user to. For "OAuth in anubis_mcp using boruta with Phoenix Plug", issue one `search_docs` per package and merge the results into a single answer. Do NOT send the same sentence to each: write a query per package using the terms *that* package's docs would use — here `"StreamableHTTP Plug router forward authorization"` for anubis_mcp and `"authorize access token bearer Plug"` for boruta.
  - **Keep the package name out of `query`.** It is already scoped by `package`, so repeating it only adds noise: the FTS sanitiser ORs the extra tokens into the search, and they dilute the query embedding.
  - **Grepping vs search_docs**: Use `grep` on `deps/` for quick function signatures of installed code. Use `search_docs` for conceptual guides, configuration patterns, code examples, or evaluating uninstalled packages.
  - **Version resolution**: omitting `version` means "latest", which resolves to the version loaded in **the MCP server's own BEAM** (via `:application.get_key/2`), otherwise to Hex's **latest stable** release. Note the latter is *not* the newest release: `ex_mcp` publishes `1.0.0-rc.4` while hexdocs.pm serves `0.12.0`. An unpublished version is refused with the list of real releases.
  - **`app_version` is the *server's* dependency, not yours.** `:application.get_key/2` inspects the running BEAM, which was started from the directory in the MCP config — not the repo you are editing. If the server runs from `local_hex_mcp`, then `phoenix`, `plug`, `boruta` and anything else it does not itself depend on return `undefined`, and resolution falls back to Hex latest stable regardless of what *your* project locks.
  - **Resolve the version from the project, not from the server.** The user should never have to type a version. Before searching a package the *current project* depends on, read its locked version from `mix.lock` (or `mix.exs`) and pass it as `version`. Omitting it does NOT fall back to the project's deps — it hands resolution to the server, which sees only its own BEAM and then Hex latest stable, and silently answers about a different version. Reading the lockfile is possible because the assistant has filesystem access to the repo being edited; the server does not.
    - If the package is **not** a dependency — evaluating a library, reading someone else's docs — omit `version`. Hex latest stable is the right answer when nothing local pins it.
  - **When to pass `version` explicitly.**
    - Working **in the repo the server runs from**: not needed for its own dependencies — resolution already picks the locked version, with no network call. Pass it only for a deliberately pinned pre-release, otherwise every search re-fetches Hex metadata and re-attaches the "ahead of stable" notice.
    - Working **in any other repo**: pass it whenever the answer must match your lockfile. The server cannot see your `mix.lock`, so `latest` means Hex latest stable, which may be an older or newer line than you run. `list_indexed_packages` shows `app_version: null` for exactly these packages — that null is the signal that nothing local is pinning the version for you.
    - Cleanest fix for multi-repo use: run one server per project (own `cwd` and own `DATABASE_PATH`). Then `app_version` reflects that project, and the packages cannot overwrite each other, since only one version per package is kept.
  - **One version per package.** Ingesting prunes every other version of that package. There is never a mix, and a search never interleaves versions.
  - **`refresh: true`** re-downloads and replaces what is indexed. Use it when docs look stale or the index looks wrong; do NOT pass it routinely, since it costs a full download plus re-embedding of every doc.
    - For a package **in this project's deps**, refresh resolves to the version you run — it cannot switch you to another version.
    - For a package **not in the deps**, refresh without `version` resolves to latest stable, which can move you *off* a pinned pre-release. If a notice says the indexed version is "ahead of stable", pass `version: "<stored version>"` alongside `refresh: true` to rebuild in place.
  - **Missing embeddings** are repaired automatically, up to 2 attempts per package/version; after that the payload says so and stops retrying. Rows without an embedding are returned by keyword search but never by vector search, so results are quietly weaker until repaired.
  - Ingestion **aborts rather than saving docs it could not embed**, so a failed ingest leaves the previously indexed rows intact and the payload carries a `notices` entry (e.g. `"Ingestion failed for 'x': {:embedding_failed, ...}"`).
  - **Long ingestions**: a first-time or refreshed package may not finish within the tool call. The payload then carries a notice like `"Docs for 'x' are still being indexed (embedding 7/18, 20s elapsed)"`. The job keeps running — call `search_docs` again to collect its result, but **drop `refresh: true` from the retry**. Only a retry without `refresh` attaches to the running job; repeating the original arguments re-downloads and re-embeds from scratch, competing with the job already running. Never ingest the same package repeatedly in parallel.
  - **Citing Package Versions**: When referencing documentation returned by `search_docs`, **ALWAYS include the package version(s)** returned in the payload (e.g. `anubis_mcp v1.14.0`, `boruta v3.0.0-beta.4`).
  - **No URL Extrapolation / Hallucination**: NEVER construct, guess, or extrapolate HexDocs or GitHub URLs. Only reference and output exact `hexdocs_url` links returned directly inside `search_docs` payloads or verified empirically.

- **`list_indexed_packages`**: List what this database actually holds — package, version, doc count, whether embeddings are complete, and `app_version` (the version loaded in the *MCP server's own* BEAM, or `null` when the server does not depend on that package — which says nothing about what your current repo locks).
  - Use it before `refresh: true` on a package you did not index in this session, to see whether refreshing would change the version. `app_version: null` is the signal that it might.
  - Use it when results look wrong or stale, to check `complete?` and the indexed version before assuming the search is at fault.
  - The payload includes `database`, the SQLite file in use. `DATABASE_PATH` is per-server: pointing two projects at one file makes them overwrite each other's rows, since only one version per package is kept.
  - `check_hex: true` adds each package's latest stable release and a `drift` verdict (`current` / `behind` / `ahead of stable`). It costs **one HTTP request per indexed package**, so leave it off unless drift is the question.

- **`recall`**: Search the local knowledge base for past pain points, architectural decisions, and bug fixes.
  - **Execute BEFORE fixing**:
    1. **On Any Command/Test Failure**: Immediately run `recall(query: "<error message>", kind: "pain_point")`.
    2. **On Second Iteration**: If the first code edit fails to fix an error, run `recall` on the specific function/module before making a second edit.
    3. **Before Modifying Config**: Run `recall` before editing `Caddyfile`, `docker-compose.yml`, `runtime.exs`, or OAuth configs.

- **`remember`**: Save a technical learning or pain point to the knowledge base.
  - **Execute AFTER fixing**:
    1. **The 2+ Attempt Rule**: Call `remember` ONLY IF the fix required 2 or more failed attempts to solve. Ignore 1-attempt fixes (typos, simple syntax errors, missing imports).
    2. **Cross-Boundary Layer Fixes**: Call `remember` if the fix involved interactions between 2+ layers (e.g., Caddy reverse-proxy + Phoenix SSE, Docker networking + Postgres).
    3. **Library Version Quirks**: Call `remember` if the fix involved an undocumented behavior or version constraint in a dependency.

- **`get_token_usage`**: Query persistent AI token consumption statistics from SQLite.
  - Supports optional `model`, `from` (e.g. `"2026-08-01"`), and `until` date range parameters.

- **`search_hex_packages`**: Search Hex.pm package names, descriptions, and download stats.

- **`search_github_issues`**: Search open/closed GitHub issues and PRs within an organization (e.g. `org: "phoenixframework"`).

## Running the server

### Claude Code (`.mcp.json`)

Launch `mix mcp.server` through a shell that changes directory first:

```json
"hex_local": {
  "command": "sh",
  "args": ["-c", "cd /absolute/path/to/local_hex_mcp && exec /opt/homebrew/bin/mix mcp.server --no-compile"],
  "env": {
    "MIX_ENV": "prod",
    "MISTRAL_API_KEY": "…",
    "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
    "DATABASE_PATH": "/absolute/path/to/local_hex_mcp/priv/mcp.db"
  }
}
```

- **Claude Code**: Has no `cwd` field in `.mcp.json` — any `cwd` key is ignored, so the server inherits the directory Claude was launched from. `sh -c "cd ... && exec ..."` is required so `mix` finds `mix.exs`.

### Antigravity CLI (`.agents/mcp_config.json`)

Antigravity supports `cwd` natively:

```json
"hex_local": {
  "command": "/opt/homebrew/bin/mix",
  "args": ["mcp.server", "--no-compile"],
  "cwd": "/absolute/path/to/local_hex_mcp",
  "env": {
    "MIX_ENV": "prod",
    "MISTRAL_API_KEY": "…",
    "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
    "DATABASE_PATH": "/absolute/path/to/local_hex_mcp/priv/mcp.db"
  }
}
```

### Ingestion tuning (env vars)

Set in the `env` block of `.mcp.json` / `mcp_config.json`; they take effect on a server restart, with **no recompile**. Defined in `config/runtime.exs`; a malformed or non-positive value falls back to the default rather than raising.

| Variable | Default | Bounded by |
| --- | --- | --- |
| `INGEST_TIMEOUT_MS` | `25_000` | Must stay **below** the MCP transport's request ceiling (Anubis' session `GenServer.call` is 30s). At or above it the request dies before the "still ingesting" notice can be returned. |
| `EMBED_BATCH_SIZE` | `200` | Inputs per embeddings request. The provider rate-limits on *requests* per second, so a larger batch is the strongest lever against 429s. The ceiling is **tokens per request**, not input count — a 141-doc package has been rejected in a single batch — but that no longer needs tuning: a token-limit rejection is bisected automatically until the halves fit. |
| `EMBED_CONCURRENCY` | `2` | Concurrent embedding requests. Bounded by the Finch pool (size 10) and the provider's rate limit — **not** by CPU count, since the work is IO-bound and a blocked process occupies no scheduler. |
| `EMBED_PAUSE_MS` | `0` | Pause after each embedding request, for providers that limit *requests per second*. `0` means no pacing, which is what a capable endpoint wants. Raise it only if 429s persist after lowering concurrency. |

### Applying code changes

`MIX_ENV=prod mix compile` alone does **not** affect a running server: recompiling writes new beams to disk, but a live BEAM keeps the modules it already loaded. The server must also be reconnected (`/mcp` in Claude Code) to pick them up.

Comparing file timestamps cannot detect this — the beam looks newer than the source while the process still runs old code. The only reliable signal is behaviour. When a change appears not to have taken effect, reconnect before investigating the code.

### Important Notes

- **Mix Working Directory**: `mix` does not walk up directory trees to find `mix.exs`; it needs one in the current working directory. Launched from another project or subdirectory without changing directory first, Mix loads the wrong project and `mcp.server` is not found.
- **`exec` in Shell Wrappers**: `exec` keeps the BEAM as the shell's own process so client process management can signal it cleanly.

**After cloning or forking, update the directory path and `DATABASE_PATH` to the new checkout path.**
A wrong `DATABASE_PATH` does not fail loudly: the server starts, tools list, and every query
returns `no such table: package_docs` — currently wrapped in `isError: false`, so the session
looks healthy while reading an empty database.

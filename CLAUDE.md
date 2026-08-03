# Local Stdio MCP (`hex_local`) Guidelines

## MCP Tools Reference

- **`search_docs`**: Search official HexDocs guides, typespecs, and code examples.
  - When asked to search documentation for specific libraries or packages (e.g. `boruta`, `anubis_mcp`, `phoenix`, `plug`), **ALWAYS extract the target package name(s)** and pass it explicitly in the `package` argument (e.g. `package: "boruta"`) to trigger Hex.pm auto-ingestion into SQLite if not yet indexed.
  - **Grepping vs search_docs**: Use `grep` on `deps/` for quick function signatures of installed code. Use `search_docs` for conceptual guides, configuration patterns, code examples, or evaluating uninstalled packages.
  - **`refresh` (re-ingestion)**: Pass `refresh: true` to re-download a package's docs from Hex.pm and replace what is indexed. Use it when docs look stale, when checking whether a **newer release** exists, or when the local index looks wrong. Do NOT pass it routinely — a re-ingest costs a full download plus re-embedding of every doc.
    - `version: "latest"` **no longer** triggers re-ingestion on its own; it only targets the newest release, and an already-indexed package is served from SQLite. `refresh` is the only way to force a re-download, and it works for a specific `version` too.
    - A package with rows missing embeddings is **reported, not repaired**: the payload carries a notice like `"Docs for 'x' have 315 entries with no embedding — those are invisible to vector search. Pass refresh: true to re-ingest the package."` Those entries are still returned by keyword search but never by vector search, so results are quietly weaker until repaired. Act on the notice with a single `refresh: true` call — do not ignore it, and do not re-run it repeatedly if it fails.
    - Ingestion aborts rather than saving docs it could not embed, so a failed ingest leaves the previously indexed rows intact. On failure the payload carries a `notices` entry (e.g. `"Ingestion failed for 'x': {:embedding_failed, ...}"`) and results still come from whatever was already indexed.
  - **Long ingestions**: A first-time or refreshed package may not finish within the tool call. The payload then carries a notice like `"Docs for 'x' are still being indexed (embedding 7/18, 20s elapsed)"`. The job keeps running — call `search_docs` again to collect its result, but **drop `refresh: true` from the retry**. Only a retry without `refresh` attaches to the running job; repeating the original arguments re-downloads and re-embeds the entire package from scratch, competing with the job already running. Never work around a slow ingestion by ingesting the same package repeatedly in parallel.
  - **Citing Package Versions**: When referencing documentation returned by `search_docs`, **ALWAYS include the package version(s)** returned in the payload (e.g. `anubis_mcp v1.14.0`, `boruta v3.0.0-beta.4`).
  - **No URL Extrapolation / Hallucination**: NEVER construct, guess, or extrapolate HexDocs or GitHub URLs. Only reference and output exact `hexdocs_url` links returned directly inside `search_docs` payloads or verified empirically.

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
| `EMBED_BATCH_SIZE` | `200` | Inputs per embeddings request. The provider rate-limits on *requests* per second, so a larger batch is the strongest lever against 429s; bounded above by the embedding model's context length. |
| `EMBED_CONCURRENCY` | `2` | Concurrent embedding requests. Bounded by the Finch pool (size 10) and the provider's rate limit — **not** by CPU count, since the work is IO-bound and a blocked process occupies no scheduler. |

### Important Notes

- **Mix Working Directory**: `mix` does not walk up directory trees to find `mix.exs`; it needs one in the current working directory. Launched from another project or subdirectory without changing directory first, Mix loads the wrong project and `mcp.server` is not found.
- **`exec` in Shell Wrappers**: `exec` keeps the BEAM as the shell's own process so client process management can signal it cleanly.

**After cloning or forking, update the directory path and `DATABASE_PATH` to the new checkout path.**
A wrong `DATABASE_PATH` does not fail loudly: the server starts, tools list, and every query
returns `no such table: package_docs` — currently wrapped in `isError: false`, so the session
looks healthy while reading an empty database.

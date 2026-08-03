# Local Stdio MCP (`hex_local`) Guidelines

## MCP Tools Reference

- **`search_docs`**: Search official HexDocs guides, typespecs, and code examples.
  - When asked to search documentation for specific libraries or packages (e.g. `boruta`, `anubis_mcp`, `phoenix`, `plug`), **ALWAYS extract the target package name(s)** and pass it explicitly in the `package` argument (e.g. `package: "boruta"`) to trigger Hex.pm auto-ingestion into SQLite if not yet indexed.
  - **Grepping vs search_docs**: Use `grep` on `deps/` for quick function signatures of installed code. Use `search_docs` for conceptual guides, configuration patterns, code examples, or evaluating uninstalled packages.
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

### Important Notes

- **Mix Working Directory**: `mix` does not walk up directory trees to find `mix.exs`; it needs one in the current working directory. Launched from another project or subdirectory without changing directory first, Mix loads the wrong project and `mcp.server` is not found.
- **`exec` in Shell Wrappers**: `exec` keeps the BEAM as the shell's own process so client process management can signal it cleanly.

**After cloning or forking, update the directory path and `DATABASE_PATH` to the new checkout path.**
A wrong `DATABASE_PATH` does not fail loudly: the server starts, tools list, and every query
returns `no such table: package_docs` — currently wrapped in `isError: false`, so the session
looks healthy while reading an empty database.

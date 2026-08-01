# Local Stdio MCP (`hex_local`) Guidelines

## MCP Tools Reference

- **`search_docs`**: Search official HexDocs guides, typespecs, and code examples.
  - When asked to search documentation for specific libraries or packages (e.g. `boruta`, `anubis_mcp`, `phoenix`, `plug`), **ALWAYS extract the target package name(s)** and pass it explicitly in the `package` argument (e.g. `package: "boruta"`) to trigger Hex.pm auto-ingestion into SQLite if not yet indexed.
  - **Grepping vs search_docs**: Use `grep` on `deps/` for quick function signatures of installed code. Use `search_docs` for conceptual guides, configuration patterns, code examples, or evaluating uninstalled packages.
  - **Citing Package Versions**: When referencing documentation returned by `search_docs`, **ALWAYS include the package version(s)** returned in the payload (e.g. `anubis_mcp v1.14.0`, `boruta v3.0.0-beta.4`).

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

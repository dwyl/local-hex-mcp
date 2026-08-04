# Local Stdio MCP Server

A lightweight Elixir MCP server designed to run over `stdio` transport with a local SQLite database.

- `search_docs`: ask a question about an Elixir package; the tool answers from the local index, or downloads and digests the package first if it is not indexed yet. A first-time ingestion of a large package may exceed one tool call — the payload then reports progress and the job continues in the background.
- `list_indexed_packages`: what is indexed, at which version, whether it is complete, and how that compares to the version this project depends on.
- `remember`: save knowledge points (pattern, pain points)
- `recall`: check your knowledge database

> you can check your LLM helper consumption with `get_token_usage`.

## Tech

- `SQLite` + FTS5 + `sqlite-vec`
- `anubis_mcp`: Compatible with Claude Code, Cursor, and Google Antigravity CLI (`agy`).
- AI models (embeddings, chat-small, chat-medium).

>[!IMPORTANT]
> It uses AI support for computing embeddings and chat completions; you must provide an **AI_API_KEY** and three models.

 |Tool                                                        | Embeddings (/embeddings)                                   | Chat Model (/chat/completions) |
  |--|--|--|
  | search_docs                                                 | Yes (embed / embed_batch)                                  | No |
 | search_hex_packages                                         | No                                                         | No |
 | search_github_issues                                        | No                                                         | No |
 | recall                                                      | Yes (embed)                                                | No |
 |  remember                                                    | Yes (embed)                                                | Yes (small & large for taxonomy & deduplication)|

<details>
<summary>Example of models</summary>

|Model|Mistral / cost|OpenAI /cost|Gemini /cost|
|--|--|--|--|
|Embeddings|mistral-embed 0.1 /M|txt-embedding-3-small 0.02 /M|text-embedding-004 0.025 /M|
|Fast extraction|mistral-small-4 0.15/0.60|GPT-5-nano 0.05,0.40 /M|gemini-2.5-flash-lite 0.10,0.40 /M|
|Classification|mistral-large-3 0.50/1.50|GPT-5-mini 0.25,2.00 /M|gemini-3.1-flash-lite 0.25,1.50 /M|

</details>

## Features

- **Hybrid search**: FTS5 selects candidates, `vec_distance_cosine` re-ranks them by semantic similarity through sqlite-vec's native C layer. Narrowing first is both more accurate and ~2x faster than ranking a whole package by vector distance.
- **Intelligent Knowledge Memory**: Multi-stage LLM curation pipeline (`decide`, `merge`, `append`, `discard`) powered by the LLM for deduplication and structuring.
- **HexDocs ingestion**: fetches a package's docs tarball from Hex, extracts it in memory, and indexes it with embeddings on demand. One HTTP request per package, never a page-by-page crawl.
- **Version-aware**: `latest` resolves to the version *this project depends on* when the package is a dependency, otherwise to Hex's latest stable release. One version per package is kept, so results never interleave versions.
- **GitHub issues** are queried live against the GitHub API and are *not* stored locally.

## Tools

| Tool | Description |
| ------ | ------------- |
| `search_docs` | Search one Hex package's documentation, typespecs, guides and examples. `package` is required; ingests on demand |
| `list_indexed_packages` | List indexed packages, versions, completeness, and the version this project depends on |
| `search_hex_packages` | Find *which* package to use — Hex.pm names, descriptions, download counts |
| `search_github_issues` | Live GitHub API search for issues and PRs in an organization (not indexed) |
| `remember` | Save a technical learning or pain point to the local knowledge base |
| `recall` | Search that knowledge base before re-investigating a failure |
| `get_token_usage` | AI token consumption recorded locally, by model and date range |

## Quickstart

### Prerequisites

- Elixir 1.20+
- [SQLite](https://www.sqlite.org/) installed
- [sqlite-vec](https://github.com/asg017/sqlite-vec) extension installed
- An AI API provider. You can test with a [Mistral](https://console.mistral.ai/) key with a generous free-tier. The MPC defaults to the Mistral models so only the keye is needed.

### Setup

Navigate to the stdio_mcp fork:

```bash
DATABASE_PATH="priv/mcp.db" mix setup
mix compile
```

### AI Code Assistant Configuration

**Claude Code / Cursor** (`.mcp.json`):

```json
{
  "mcpServers": {
    "hex_local": {
      "command": "sh",
      "args": [
        "-c",
        "cd /absolute/path/to/local_hex_mcp && exec /opt/homebrew/bin/mix mcp.server --no-compile"
      ],
      "env": {
        "MIX_ENV": "prod",
        "MISTRAL_API_KEY": "your-key-here",
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "DATABASE_PATH": "/absolute/path/to/local_hex_mcp/priv/mcp.db"
      }
    }
  }
}
```

**Google Antigravity** (`.agents/mcp_config.json`):

```json
{
  "mcpServers": {
    "hex_local": {
      "command": "mix",
      "args": ["mcp.server", "--no-compile"],
      "cwd": "/absolute/path/to/local_hex_mcp",
      "env": {
        "MIX_ENV": "prod",
        "MIX_QUIET": "1",
        "MISTRAL_API_KEY": "your-key-here",
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
      }
    }
  }
}
```

### Ingestion tuning

Set in the `env` block of your MCP config; they take effect on a server restart, with no recompile. A malformed value falls back to the default rather than raising.

| Variable | Default | Notes |
| --- | --- | --- |
| `INGEST_TIMEOUT_MS` | `25000` | How long a search waits for an in-flight ingestion. Must stay **below** the MCP transport's request ceiling (Anubis' session call gives up at 30s), or the request dies before the progress notice can be returned. |
| `EMBED_BATCH_SIZE` | `200` | Inputs per embeddings request. The provider limits *requests* per second, so larger batches reduce 429s. The real ceiling is tokens per request, but a token-limit rejection is bisected automatically, so this rarely needs tuning. |
| `EMBED_CONCURRENCY` | `2` | Concurrent embedding requests. Bounded by the Finch pool and the provider's rate limit — not by CPU count; the work is IO-bound. |
| `EMBED_PAUSE_MS` | `0` | Pause after each embedding request, for providers that limit requests per second. `0` means no pacing. Raise only if 429s persist after lowering concurrency. |

> Changing code requires `MIX_ENV=prod mix compile` **and** reconnecting the MCP server — recompiling alone does not reload modules into a running BEAM.

### Telemetry

The tool `get_token_usage` returns the token consumption.

The query:

```bash
get_token_usage(from: "2026-08-01", until: "2026-08-01")
```

returns a clean human-friendly Markdown

<details>

<summary>example</summary>

```json
    {
      "total_requests": 12,
      "total_tokens": 10450,
      "total_prompt_tokens": 8200,
      "total_completion_tokens": 2250,
      "period": {
        "from": "2026-08-01",
        "until": "2026-08-01"
      },
      "by_model": {
        "mistral-embed": {
          "requests": 8,
          "prompt_tokens": 6500,
          "completion_tokens": 0,
          "total_tokens": 6500
        },
        "mistral-small-latest": {
          "requests": 4,
          "prompt_tokens": 1700,
          "completion_tokens": 2250,
          "total_tokens": 3950
        }
      }
    }
  ```

</details>  

### Optional: Litestream replication

Replicate your SQLite database to cloud storage (S3, B2, etc.) for backup and portability.

1. Install [Litestream](https://litestream.io/install/)
2. Configure replication for `DATABASE_PATH`

### MIsc: Knowledge Decision taxonomy

| Action | When | What happens |
| ----------- | ------------------------------------------------------- | --------------------------------------- |
| **create** | No similar neighbors (similarity < 0.7) | New entry |
| **discard** | Too similar (> 0.9), no additional value | Do nothing |
| **append** | Similar neighbor, new info adds value | Concatenate to existing content |
| **merge** | Overlapping but complementary info | Synthesize old + new into one entry |
| **replace** | Old info is factually wrong/superseded | Replace content of existing entry |
| **deprecate** | Neighbor is outdated by new info | Mark old as `outdated=true` |

## Important example on how to use `search-docs`

In the Code assistant terminal (the hex_local MCP is connected), ask a normal question — you do not call the tool yourself:

```txt
sketch an OAuth implementation for anubis_mcp without an external
provider, using the Boruta package with Phoenix Plug
```

A search is scoped to **one** package, so the Code assistant decomposes this into one
call per package and consolidates the answers. It also writes a query per
package using the terms that package's docs actually use, rather than sending
your sentence twice.

Three things about the arguments it fills in:

1. **Name the package exactly as it is on Hex** — `anubis_mcp`, not "Anubis" or
   "the MCP library". The server matches `package` literally and never reads
   package names out of your question; a name that appears only in the question
   returns rows from unrelated packages that happen to share keywords.

2. **You do not need to give a version.** The assistant reads it from your
   project's `mix.lock` and passes it, because the (MCP) server cannot see your
   lockfile — it only knows its own dependencies and Hex's latest *stable*
   release. That inference is what makes naming the package enough. Without it
   you would silently get the wrong line: `boruta` above is `3.0.0-beta.4`, while
   Hex's latest stable is `2.3.8`, and nothing in the answer would say so.

3. **You can pin a version yourself** — "use boruta 3.0.0-beta.4" — but note it
   is **not** a filter: only **one version** per package is kept, so asking for a version
   that is not the indexed one **re-downloads it and replaces what is stored**.
   Harmless when you mean it, surprising when you did not. `list_indexed_packages`
   shows what is currently held.

With the input above, the Code assistant will run:

```elixir
search_docs(package: "anubis_mcp", version: "1.14.0",
            query: "StreamableHTTP Plug router forward authorization")

search_docs(package: "boruta", version: "3.0.0-beta.4",
            query: "authorize access token bearer Plug protect resource")
```

Any package not already indexed is downloaded, chunked and embedded first. Each
search then runs FTS5 candidate selection followed by vector re-ranking, and the
assistant merges the two result sets:

<details>
<summary>Results:</summary>

```markdown
  ──────

 — anubis_mcp v1.14.0 + boruta v3.0.0-beta.4:

1. Mount the MCP endpoint behind an auth pipeline

transports.html#serving-over-http — the server process and the HTTP endpoint are separate: you supervise the first, mount the second.

# lib/my_app_web/router.ex
pipeline :mcp do
  plug :accepts, ["json"]
  plug MyAppWeb.Plugs.Authorization, :require_authenticated
end

scope "/mcp" do
  pipe_through :mcp
  forward "/", Anubis.Server.Transport.StreamableHTTP.Plug, server: MyApp.Server
end

# supervision tree
children = [MyAppWeb.Endpoint, {MyApp.Server, transport: :streamable_http}]

2. Authorize with Boruta's own bearer extraction

authorize_requests.html — in a monolith you call the Boruta API directly; a Plug in the pipeline is the preferred shape.

defmodule MyAppWeb.Plugs.Authorization do
  import Plug.Conn
  alias Boruta.Oauth.{Authorization, BearerToken, Scope}

  def require_authenticated(conn, _opts) do
    with {:ok, bearer} <- BearerToken.extract_token(conn),
         {:ok, token} <- Authorization.AccessToken.authorize(value: bearer) do
      assign(conn, :current_token, token)
    else
      _ -> conn |> put_status(:unauthorized) |> halt()
    end
  end
end

Scope enforcement is a second plug, applied per action:

plug :authorize, ["resource:read"]  when action in [:index, :show]
plug :authorize, ["resource:write"] when action in [:create, :update, :delete]

3. Tag SSE subscribers with the authenticated subject

Plug configuration options — :subscriber_metadata takes (Plug.Conn.t() -> map()), called when an SSE stream opens, letting you later target send_message_to_subscribers/4 by tenant or user:

forward "/", Anubis.Server.Transport.StreamableHTTP.Plug,
  server: MyApp.Server,
  subscriber_metadata: &MyApp.sse_metadata/1   # remote capture survives plug option escaping

---
  ```

</details>

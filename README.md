# Local Stdio MCP Server

A lightweight Elixir MCP server designed to run over `stdio` transport.

## Tech

- `SQLite` + FTS5 + `sqlite-vec`
- `anubis_mcp`: Compatible with Claude Code, Cursor, and Google Antigravity CLI (`agy`).
- AI models (embeddings, chat-small, chat-medium).

>[!IMPORTANT]
> It uses AI support for computing embeddings and chat completions, thus an **AI_API_KEY** and three models.

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

- **Hybrid search**: FTS5 broadens candidates, `vec_distance_cosine` re-ranks by semantic similarity — all in a single SQL query via sqlite-vec's native C layer.
- **Intelligent Knowledge Memory**: Multi-stage LLM curation pipeline (`decide`, `merge`, `append`, `discard`) powered by Mistral for deduplication and structuring.
- **HexDocs & Hex.pm Ingestion**: Auto-fetches and indexes package documentation and GitHub issues on demand using Mistral embeddings.

## Tools

| Tool | Description |
| ------ | ------------- |
| `search_docs` | Search Hex package documentation, typespecs, and code examples |
| `search_hex_packages` | Search Hex.pm packages by keyword |
| `search_github_issues` | Search GitHub issues and pull requests within an organization |
| `remember` | Save a technical learning or pain point to the knowledge base |
| `recall` | Search the knowledge base for relevant technical learnings |

## Quickstart

### Prerequisites

- Elixir 1.15+
- [SQLite](https://www.sqlite.org/) installed
- [sqlite-vec](https://github.com/asg017/sqlite-vec) extension installed
- An AI API provider, eg [Mistral](https://console.mistral.ai/)

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

**Google Antigravity** (`agents/mcp_config.json`):

```json
{
  "mcpServers": {
    "hex_local": {
      "command": "mix",
      "args": ["mcp.server", "--no-compile"],
      "cwd": "/absolute/path/to/stdio",
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

## Example

In the Code assistant terminal (the hex_local MCP is connected), enter:

```bash
search-docs "sketch OAuth implementation in anubis_mcp 
without using an external provider 
but by using the Boruta package with Phoenix Plug"
```

If not already digested in the database, the packages `anubis_mcp` and `boruta` will by downloaded, chunked and embedded into the SQLite database.
The MCP tool will then run a hybrid FST+similarity search and send a response digested by the Code assistant:

<details>
<summary>Results:</summary>

```markdown
  ──────

### Complete Architecture Sketch: OAuth in anubis_mcp using Boruta + Phoenix Plug

  Here is the complete implementation design combining official anubis_mcp and Boruta patterns:

  #### 1. OAuth Server Route Setup (lib/my_app_web/router.ex)

  Boruta provides Phoenix controllers for PKCE authorization, client registration, and token management:

    defmodule MyAppWeb.Router do
      use MyAppWeb, :router

      # 1. RFC 9728 Protected Resource Metadata (Discovery)
      scope "/.well-known", MyAppWeb.OAuth do
        pipe_through :api
        get "/oauth-protected-resource", WellKnownController, :protected_resource
      end

      # 2. Browser Flow for PKCE (Login + Scope Consent)
      scope "/oauth", MyAppWeb.OAuth do
        pipe_through :oauth_browser
        get "/authorize", AuthorizeController, :authorize
      end

      # 3. OAuth API Endpoints (Token Exchange & Registration)
      scope "/oauth", MyAppWeb.OAuth do
        pipe_through :api
        post "/token", TokenController, :token
        post "/register", RegistrationController, :register
      end

      # 4. Protected Streamable HTTP MCP Endpoint
      scope "/mcp" do
        pipe_through [:api, MyAppWeb.Plugs.MCPAuthorizationPlug]

        forward "/", Anubis.Server.Transport.StreamableHTTP.Plug, server: MyApp.MCPServer
      end
    end
    ──────
  #### 2. The Authorization Plug (lib/my_app_web/plugs/mcp_authorization_plug.ex)

  In a monolithic Phoenix application, you can authorize incoming Bearer tokens directly using Boruta.Oauth.Authorization.AccessToken:

    defmodule MyAppWeb.Plugs.MCPAuthorizationPlug do
      import Plug.Conn
      alias Boruta.Oauth.Authorization

      def init(opts), do: opts

      def call(conn, _opts) do
        with [authorization_header] <- get_req_header(conn, "authorization"),
             [_, bearer_token] <- Regex.run(~r/[B|b]earer (.+)/, authorization_header),
             {:ok, %Boruta.Oauth.Token{expires_at: expires_at} = token} <- Authorization.AccessToken.authorize(value: bearer_token),
             true <- expires_at > :os.system_time(:second) do

          # Store validated token & subject in conn assigns
          assign(conn, :current_token, token)
        else
          _ ->
            unauthorized(conn)
        end
      end

      defp unauthorized(conn) do
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header(
          "www-authenticate",
          ~s(Bearer resource_metadata="https://api.example.com/.well-known/oauth-protected-resource")
        )
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
        |> halt()
      end
    end
    ──────
  #### 3. Defining the MCP Server (lib/my_app/mcp_server.ex)

  Because authentication and token verification occur at the Phoenix Plug pipeline level, Anubis.Server simply defines the tools and components:

    defmodule MyApp.MCPServer do
      use Anubis.Server,
        name: "my_mcp_server",
        version: "1.0.0",
        capabilities: [:tools]

      component(MyApp.Tools.Echo)
      component(MyApp.Tools.SearchDocs)
    end
    ──────
  ### Summary of the Flow

  1. Client Registration: MCP clients register dynamically at POST /oauth/register.
  2. PKCE Token Issuance: The client initiates authorization code flow via GET /oauth/authorize and exchanges the code for a token at POST /oauth/token.
  3. MCP Request Validation: Incoming POST /mcp requests carry Authorization: Bearer <token>. MCPAuthorizationPlug verifies the token in Postgres via Boruta.Oauth.Authorization.
  AccessToken.authorize/1.
  4. Execution: Anubis.Server.Transport.StreamableHTTP.Plug executes the MCP tool call and streams responses back over HTTP/SSE.
  ```

</details>

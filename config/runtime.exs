import Config

# `AI_*` is the canonical spelling for every provider setting. The endpoint is
# pluggable — Mistral, OpenAI, Gemini, Cohere all speak a close-enough
# embeddings API — and naming the variables after one vendor made the config
# read as though it were not.
#
# The `MISTRAL_*` spellings no longer resolve to anything. They are still
# *detected*, and only so the server can say so: two names for one setting, with
# precedence between them, is how `anubis_mcp` came to be indexed at 1536
# dimensions (codestral-embed) while every query embedded at 1024
# (mistral-embed). sqlite-vec refuses that pair, `Docs.Search.run_query/4`
# rescues the error, and the search answers from FTS alone — the vector arm was
# dead for that package and nothing reported it. A fallback that quietly supplies
# a value the operator did not intend is the same failure in a smaller costume,
# so the legacy name gets a sentence and no effect.
#
# stderr, not stdout: stdout carries JSON-RPC and must stay clean.
for {legacy, canonical} <- [
      {"MISTRAL_API_URL", "AI_API_URL"},
      {"MISTRAL_API_KEY", "AI_API_KEY"},
      {"MISTRAL_MODEL_EMBED", "AI_EMBED_MODEL"},
      {"MISTRAL_MODEL_SMALL", "AI_CHAT_MODEL_SMALL"},
      {"MISTRAL_LARGE_MODEL", "AI_CHAT_MODEL_LARGE"}
    ],
    not is_nil(System.get_env(legacy)),
    is_nil(System.get_env(canonical)) do
  IO.puts(:stderr, "[config] #{legacy} is no longer read — rename it to #{canonical}")
end

config :stdio_mcp,
  ai_api_url: System.get_env("AI_API_URL", "https://api.mistral.ai/v1"),
  ai_api_key: System.get_env("AI_API_KEY"),
  ai_embed_model: System.get_env("AI_EMBED_MODEL", "mistral-embed"),
  ai_chat_model_small: System.get_env("AI_CHAT_MODEL_SMALL", "mistral-small-latest"),
  ai_chat_model_large: System.get_env("AI_CHAT_MODEL_LARGE", "mistral-large-latest"),
  github_api_url: System.get_env("GITHUB_API_URL", "https://api.github.com"),
  github_token: System.get_env("GITHUB_TOKEN"),
  hex_api_url: System.get_env("HEX_API_URL", "https://hex.pm/api")

# Ingestion tuning. These three are the values that actually depend on the
# environment rather than on the code: the MCP client's request ceiling and the
# embedding provider's rate limit. Exposed as env vars so they can be adjusted
# from .mcp.json and take effect on a server restart, with no recompile.
#
# Parsing never raises — a malformed value falls back to the default rather than
# taking down every release command that loads this file.
env_int = fn name, default ->
  with value when is_binary(value) <- System.get_env(name),
       {parsed, ""} <- Integer.parse(String.trim(value)),
       true <- parsed > 0 do
    parsed
  else
    _ -> default
  end
end

config :stdio_mcp,
  # Must stay below the MCP transport's own request timeout (Anubis' session
  # GenServer.call is 30s) — at or above it the request dies before the
  # "still ingesting" notice can be returned.
  ingest_timeout_ms: env_int.("INGEST_TIMEOUT_MS", 25_000),
  # Inputs per embeddings request. Mistral rate-limits on requests_per_second,
  # so a bigger batch is the strongest lever against 429s; bounded above by the
  # model's context length.
  embed_batch_size: env_int.("EMBED_BATCH_SIZE", 200),
  # Concurrent embedding requests. Bounded by the Finch pool (size 10) and the
  # provider's rate limit — not by CPU count.
  embed_concurrency: env_int.("EMBED_CONCURRENCY", 2),
  # Pause after each embedding request, for providers that limit
  # requests-per-second. 0 (the default) means no pacing at all, which is what a
  # capable endpoint wants; raise it only if 429s persist after lowering
  # concurrency.
  embed_pause_ms: env_int.("EMBED_PAUSE_MS", 0)

repo_overrides =
  [load_extensions: [SqliteVec.path()]] ++
    if(db_path = System.get_env("DATABASE_PATH"), do: [database: db_path], else: [])

config :stdio_mcp, StdioMcp.Repo, repo_overrides

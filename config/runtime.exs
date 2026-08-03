import Config

config :stdio_mcp,
  ai_api_url:
    System.get_env("AI_API_URL") || System.get_env("MISTRAL_API_URL", "https://api.mistral.ai/v1"),
  ai_api_key: System.get_env("AI_API_KEY") || System.get_env("MISTRAL_API_KEY"),
  ai_embed_model:
    System.get_env("AI_EMBED_MODEL") || System.get_env("MISTRAL_MODEL_EMBED", "mistral-embed"),
  ai_chat_model_small:
    System.get_env("AI_CHAT_MODEL_SMALL") ||
      System.get_env("MISTRAL_MODEL_SMALL", "mistral-small-latest"),
  ai_chat_model_large:
    System.get_env("AI_CHAT_MODEL_LARGE") ||
      System.get_env("MISTRAL_LARGE_MODEL", "mistral-large-latest"),
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
  embed_concurrency: env_int.("EMBED_CONCURRENCY", 2)

repo_overrides =
  [load_extensions: [SqliteVec.path()]] ++
    if(db_path = System.get_env("DATABASE_PATH"), do: [database: db_path], else: [])

config :stdio_mcp, StdioMcp.Repo, repo_overrides

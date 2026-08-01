import Config

config :stdio_mcp,
  ai_api_url: System.get_env("AI_API_URL") || System.get_env("MISTRAL_API_URL", "https://api.mistral.ai/v1"),
  ai_api_key: System.get_env("AI_API_KEY") || System.get_env("MISTRAL_API_KEY"),
  ai_embed_model: System.get_env("AI_EMBED_MODEL") || System.get_env("MISTRAL_MODEL_EMBED", "mistral-embed"),
  ai_chat_model_small: System.get_env("AI_CHAT_MODEL_SMALL") || System.get_env("MISTRAL_MODEL_SMALL", "mistral-small-latest"),
  ai_chat_model_large: System.get_env("AI_CHAT_MODEL_LARGE") || System.get_env("MISTRAL_LARGE_MODEL", "mistral-medium-latest"),
  github_api_url: System.get_env("GITHUB_API_URL", "https://api.github.com"),
  github_token: System.get_env("GITHUB_TOKEN"),
  hex_api_url: System.get_env("HEX_API_URL", "https://hex.pm/api")

repo_overrides =
  [load_extensions: [SqliteVec.path()]] ++
    if(db_path = System.get_env("DATABASE_PATH"), do: [database: db_path], else: [])

config :stdio_mcp, StdioMcp.Repo, repo_overrides

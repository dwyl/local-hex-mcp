import Config

config :stdio_mcp,
  ecto_repos: [StdioMcp.Repo]

# config :nx, default_backend: EMLX.Backend
config :nx, default_backend: EXLA.Backend

# source: https://micrologics.org/blog/sqlite-in-production-optimizing-wal-mode-concurrency-and-vfs-layers-for-low-latency-app-servers
config :stdio_mcp, StdioMcp.Repo,
  database: Path.expand("../priv/mcp.db", __DIR__),
  pool_size: 5,
  journal_mode: :wal,
  busy_timeout: 5000,
  # Auto-checkpointing (every 1000 pages) already runs, but SQLite defaults
  # journal_size_limit to -1, which means the -wal file is never truncated back
  # down: it keeps whatever high-water mark an ingestion burst produced. With a
  # limit set, each checkpoint truncates the file to this size.
  journal_size_limit: 16 * 1024 * 1024

config :logger, :default_formatter, format: "$time [$level] $message\n"

config :logger, :default_handler, config: [type: :standard_error]

config :logger, level: :error

import_config "#{config_env()}.exs"

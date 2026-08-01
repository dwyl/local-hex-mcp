import Config

config :stdio_mcp,
  ecto_repos: [StdioMcp.Repo]

config :stdio_mcp, StdioMcp.Repo,
  database: Path.expand("../priv/mcp.db", __DIR__),
  pool_size: 5,
  journal_mode: :wal,
  busy_timeout: 5000

config :logger, :default_formatter, format: "$time [$level] $message\n"

config :logger, :default_handler, config: [type: :standard_error]

config :logger, level: :error

import_config "#{config_env()}.exs"

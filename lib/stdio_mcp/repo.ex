defmodule StdioMcp.Repo do
  use Ecto.Repo,
    otp_app: :stdio_mcp,
    adapter: Ecto.Adapters.SQLite3
end

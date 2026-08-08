defmodule StdioMcp.MixProject do
  use Mix.Project

  def project do
    # `mcp.server` owns stdout: the client parses it as JSON-RPC, so a single
    # line of Mix chatter or a log record corrupts the stream. This covers the
    # window before `Mix.Tasks.Mcp.Server.run/1` sets the quiet shell itself.
    #
    # It used to key on `MIX_ENV == "prod"`, using the environment as a proxy for
    # "this is the MCP server" because .mcp.json launches it that way. That
    # silenced *every* prod task: `mix docs.eval` ran all 28 queries, built every
    # table, discarded the lot and exited 0 — indistinguishable from a task that
    # does no work, and impossible to diagnose from the outside because no
    # redirection, tee or shell could recover output that was never written.
    if quiet_stdout?() do
      Mix.shell(Mix.Shell.Quiet)
      :logger.update_handler_config(:default, :config, %{type: :standard_error})
    end

    [
      app: :stdio_mcp,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: false,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit]
      ],
      releases: [
        stdio_mcp: [
          include_executables_for: [:unix],
          applications: [stdio_mcp: :permanent]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets],
      mod: {StdioMcp.Application, []}
    ]
  end

  # `System.argv()` at project-load time is the Mix argument list, so the task
  # name is its head. `MIX_QUIET=1` stays as the manual override for anything
  # else that needs a clean stdout.
  defp quiet_stdout? do
    System.get_env("MIX_QUIET") == "1" or match?(["mcp.server" | _], System.argv())
  end

  defp deps do
    [
      # {:anubis_mcp, path: "vendor/anubis_mcp"},
      {:anubis_mcp, "~> 2.0.0"},
      {:ecto_sqlite3, "~> 0.17"},
      {:sqlite_vec, "~> 0.1"},
      {:finch, "~> 0.18"},
      {:req, "~> 0.5"},
      {:text_chunker, "~> 0.6"},
      {:jason, "~> 1.4"},
      {:lazy_html, "~> 0.1.12"},
      {:mdex, "~> 0.13.5"},
      {:dialyxir, "~> 1.4", runtime: false},
      {:credo, "~> 1.7", runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"]
    ]
  end
end

defmodule StdioMcp.MixProject do
  use Mix.Project

  def project do
    if System.get_env("MIX_ENV") == "prod" or System.get_env("MIX_QUIET") == "1" do
      Mix.shell(Mix.Shell.Quiet)
      :logger.update_handler_config(:default, :config, %{type: :standard_error})
    end

    [
      app: :stdio_mcp,
      version: "0.1.0",
      elixir: "~> 1.15",
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

  defp deps do
    [
      {:anubis_mcp, "~> 1.14.0"},
      {:ecto_sqlite3, "~> 0.17"},
      {:sqlite_vec, "~> 0.1"},
      {:finch, "~> 0.18"},
      {:req, "~> 0.5"},
      {:text_chunker, "~> 0.6"},
      {:jason, "~> 1.4"},
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

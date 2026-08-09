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
      releases: releases()
    ]
  end

  # A plain Mix release, verified to work over stdio: the boot script execs
  # `elixir --no-halt`, which sets `-noshell` but not `-noinput`, and `vm.args`
  # adds nothing, so the transport can still read stdin. Feeding it a JSON-RPC
  # `initialize` returns a correct response on stdout with an empty stderr.
  #
  # There is deliberately no Burrito build here, and the reason is the audience
  # rather than the tooling. Burrito exists to ship an Elixir application to
  # people who do not have Elixir; everyone who can use this server is writing
  # Elixir on a machine that must have it, in a repo where they are already
  # running mix commands. The one install step a self-extracting binary removes
  # is the step this audience is guaranteed to be equipped for. (Expert is
  # burrito-packaged and also Elixir-only, but an *editor* installs it for
  # someone who never asked; nobody hand-writes a config for it. Here you do.)
  #
  # It was built and measured before being dropped, so the findings are recorded
  # rather than left to be rediscovered:
  #
  #   * Packaging itself works. 43MB binary, NIFs intact, `sqlite_vec`'s `vec0`
  #     extension loads from the extracted directory, OTP 29 ERTS bundled with no
  #     `custom_erts`, and a prod build caches the extraction (~0.9s launch). A
  #     dev build re-extracts 1718 files every launch, which makes any stdio
  #     timing measurement meaningless.
  #   * It cannot answer. The server starts, reads stdin correctly and exits
  #     cleanly on EOF, but writes **zero bytes to stdout** where this plain
  #     release writes 147, through an identical harness. Input works; only the
  #     reply is lost. Ruled out by measurement: self-halting (it waits for EOF,
  #     10.008s against the plain release's 10.026s), extraction timing, and
  #     startup failure. Untested hypothesis: `:stdio` resolves through the group
  #     leader under `-noshell`, and Burrito launches Erlang itself via
  #     `execve()` rather than through the release's `bin/` script.
  #   * Burrito 1.6.0's README asks for Zig 0.15.2; its code requires **0.16.0**
  #     and enforces it with an exact `!=` in `Burrito.check_zig_version/0`.
  #     Following the README costs a toolchain downgrade and a failed build.
  #
  # Separately, a *distributable* binary would need more than the wrapper:
  # `config/config.exs` computes the database path with
  # `Path.expand("../priv/mcp.db", __DIR__)` at compile time, so a binary carries
  # the build machine's path. That would have to be resolved at runtime, with
  # migrations run at boot, since `mix setup` does not exist inside a release.
  defp releases do
    [
      stdio_mcp: [
        include_executables_for: [:unix],
        applications: [stdio_mcp: :permanent]
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

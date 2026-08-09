defmodule StdioMcp.Application do
  @moduledoc false
  use Application

  alias StdioMcp.AI.Client

  @impl true
  def start(_type, _args) do
    # Redirect Erlang logger to stderr so stdout stays completely clean for JSON-RPC
    :logger.update_handler_config(:default, :config, %{type: :standard_error})
    :io.setopts(:standard_io, encoding: :utf8)

    setup_file_logging()

    # Attach Telemetry handler to record AI token usage into SQLite
    StdioMcp.Telemetry.attach()

    # One pool per distinct endpoint. Embeddings and chat usually share a provider
    # and collapse to a single entry; when they do not — a local embedding server
    # with chat still on a hosted provider — an unlisted host would silently fall
    # back to Finch's default pool instead of the size configured here.
    pools =
      [Client.embed_url(), Client.chat_url()]
      |> Enum.uniq()
      |> Map.new(&{&1, [size: 10]})

    children =
      [
        StdioMcp.Repo,
        {Finch, name: StdioMcp.Finch, pools: pools},
        # Two registries back StdioMcp.Docs.IngestionJob: the unique one names the
        # single in-flight job per {module, package, version}, the duplicate one
        # holds every caller waiting on it.
        {Registry, keys: :unique, name: StdioMcp.IngestionRegistry},
        {Registry, keys: :duplicate, name: StdioMcp.IngestionWaiters},
        StdioMcp.Docs.RepairBudget,
        {Task.Supervisor, name: StdioMcp.TaskSupervisor}
      ] ++ mcp_children()

    opts = [strategy: :one_for_one, name: StdioMcp.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        if stdio_transport?(), do: spawn(&monitor_transport_and_halt/0)
        {:ok, pid}

      other ->
        other
    end
  end

  # Adds a file log alongside the stderr handler, enabled by MCP_LOG_FILE.
  #
  # Gated on an env var rather than Mix.env because .mcp.json runs the server
  # with MIX_ENV=prod — a dev-only setting would never apply to a real session,
  # which is precisely when stderr is discarded by the MCP client and the log is
  # the only way to see what happened.
  #
  # The primary level has to be lowered too: it filters before handlers, so with
  # the default `level: :error` no warning ever reaches a handler. Several hot
  # paths rescue and fall back silently (run_query, ensure_ingested,
  # maybe_auto_ingest, run_fts_knowledge), and those warnings are the point.
  defp setup_file_logging do
    case System.get_env("MCP_LOG_FILE") do
      path when is_binary(path) and path != "" ->
        level = log_level()
        :logger.set_primary_config(:level, level)

        :logger.add_handler(:mcp_file, :logger_std_h, %{
          level: level,
          # `filesync_repeat_interval` defaults to 5s, and the transport monitor
          # ends the session with System.halt/1, which does not flush handler
          # buffers — a short session would otherwise leave an empty file.
          config: %{file: String.to_charlist(path), filesync_repeat_interval: 500},
          formatter:
            {:logger_formatter,
             %{
               template: [:time, " [", :level, "] ", :msg, "\n"],
               single_line: true
             }}
        })

      _ ->
        :ok
    end
  end

  defp flush_file_log do
    case :logger.get_handler_config(:mcp_file) do
      {:ok, _config} -> :logger_std_h.filesync(:mcp_file)
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp log_level do
    case System.get_env("MCP_LOG_LEVEL", "warning") do
      "debug" -> :debug
      "info" -> :info
      "error" -> :error
      _ -> :warning
    end
  end

  # The stdio transport takes over stdin/stdout for JSON-RPC, and
  # `monitor_transport_and_halt/0` halts the VM as soon as it sees EOF. Started
  # unconditionally, that makes every other way of booting the app unusable:
  # `mix run` produces no output and exits 0 before the script finishes, so
  # seeds and maintenance tasks silently do nothing.
  #
  # `mix mcp.server` sets MCP_TRANSPORT itself, so client configs need no change.
  defp mcp_children do
    if stdio_transport?() do
      # Anubis expires a session after 30 minutes with no request and does not
      # tell the client. Claude Code goes on showing the server as connected, and
      # the next tool call reaches a transport with no session to dispatch to —
      # it hangs until the client's own timeout rather than failing fast.
      #
      # Thirty minutes of no *tool calls* is completely ordinary in a coding
      # session: you edit, run tests, read, think. Observed exactly that today,
      # a 5-hour gap between searches, and both calls hung past 120s with
      # `no_session` in the log.
      #
      # The timeout exists for HTTP transports holding many sessions. A stdio
      # server has exactly one, and it should live as long as the transport, so
      # this is set to a working day rather than tuned.
      [{StdioMcp.MCPServer, transport: :stdio, session_idle_timeout: to_timeout(hour: 8)}]
    else
      []
    end
  end

  defp stdio_transport?, do: System.get_env("MCP_TRANSPORT") == "stdio"

  # Two processes are watched, because they fail differently and only one of them
  # was ever handled.
  #
  # The **transport** dies on stdin EOF: the client closed the pipe, so halt at
  # once. That was the whole of this function, and it left a gap — a `/mcp`
  # reconnect starts a replacement server without closing the old one's stdin, so
  # the old transport waits in `receive` forever. Four such servers accumulated
  # in a day, one alive for 17 hours, each holding a five-connection SQLite pool
  # and ~100MB. Antigravity is better behaved: it sends SIGTERM and the process
  # exits cleanly, which is how the reconnect path was identified as the leak.
  #
  # The **session** dies on idle expiry, and nothing restarts it. The transport
  # survives, answers `no_session`, and every later tool call hangs until the
  # client's own timeout — a server that is up and cannot work. So a session that
  # stays down is a dead server too.
  #
  # "Stays" is load-bearing. A crash may be followed by a supervisor restart, and
  # halting through a recoverable failure would turn a blip into an outage, so the
  # session going down starts a grace period and then *rechecks the registry*
  # rather than trusting the DOWN alone.
  @session_grace_ms to_timeout(second: 30)

  @dialyzer {:no_return, monitor_transport_and_halt: 0}
  defp monitor_transport_and_halt do
    transport_name = Anubis.Server.Registry.transport_name(StdioMcp.MCPServer, :stdio)
    session_name = Anubis.Server.Registry.stdio_session_name(StdioMcp.MCPServer)

    transport_ref = Process.monitor(await_pid(transport_name))
    session_ref = Process.monitor(await_pid(session_name))

    receive do
      {:DOWN, ^session_ref, :process, _pid, _reason} ->
        Process.sleep(@session_grace_ms)

        if is_pid(Process.whereis(session_name)) do
          # Restarted — drop the stale transport monitor and watch the new pair.
          Process.demonitor(transport_ref, [:flush])
          monitor_transport_and_halt()
        else
          flush_file_log()
          System.halt(0)
        end

      {:DOWN, ^transport_ref, :process, _pid, _reason} ->
        # System.halt/1 exits without running the shutdown sequence, so buffered
        # handler output is lost — the file log of a short session would be
        # empty. Sync explicitly before going down.
        flush_file_log()
        System.halt(0)
    end
  end

  defp await_pid(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        pid

      nil ->
        Process.sleep(50)
        await_pid(name)
    end
  end
end

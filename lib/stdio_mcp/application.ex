defmodule StdioMcp.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Redirect Erlang logger to stderr so stdout stays completely clean for JSON-RPC
    :logger.update_handler_config(:default, :config, %{type: :standard_error})

    setup_file_logging()

    # Attach Telemetry handler to record AI token usage into SQLite
    StdioMcp.Telemetry.attach()

    provider = Application.get_env(:stdio_mcp, :ai_api_url, "https://api.mistral.ai")

    children =
      [
        StdioMcp.Repo,
        {Finch, name: StdioMcp.Finch, pools: %{provider => [size: 10]}},
        # Two registries back StdioMcp.Docs.IngestionJob: the unique one names the
        # single in-flight job per {module, package, version}, the duplicate one
        # holds every caller waiting on it.
        {Registry, keys: :unique, name: StdioMcp.IngestionRegistry},
        {Registry, keys: :duplicate, name: StdioMcp.IngestionWaiters},
        StdioMcp.Docs.RepairBudget,
        {Task.Supervisor, name: StdioMcp.TaskSupervisor},
        {Nx.Serving, serving: serving_reranker(), name: Rerank}
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

  # defp set_backend() do
  #   case :os.type() do
  #     {:unix, :darwin} -> "EMLX"
  #     _ -> "EXLA"
  #   end
  # end

  # Not every reranker on HuggingFace loads here: `Bumblebee.Text.cross_encoding`
  # needs an architecture Bumblebee implements with a sequence-classification
  # head, which rules out most of the current state of the art before quality
  # enters the picture. Checked 2026-08-06:
  #
  #   cross-encoder/ms-marco-MiniLM-L-6-v2       OK   Bert, 22M   (default)
  #   cross-encoder/ms-marco-MiniLM-L-12-v2      OK   Bert, 33M
  #   BAAI/bge-reranker-base                     OK   Roberta, 278M
  #   mixedbread-ai/mxbai-rerank-xsmall-v1       no   DebertaV2 unsupported
  #   jinaai/jina-reranker-v2-base-multilingual  no   custom arch, weights unreadable
  #
  # `sequence_length` is the setting that matters most and the one that looks
  # least important. At 128 the query/document pair is truncated to roughly 400
  # characters: a symbol query still works, because the identifier is in the
  # header, while a conceptual answer usually sits deeper in the chunk and is
  # simply not seen. Measured on the 26-query eval, reranking at 128 scored
  # *worse* than not reranking at all (0.88 recall@5 against hybrid's 0.92); at
  # 512 it scores 1.00. See Notes.md for the full sweep.
  #
  # `batch_size` should track the rerank depth: Nx.Serving pads a short batch to
  # the compiled size, so a 10-candidate pool costs the same as 20 when compiled
  # for 20.
  @default_rerank_model "cross-encoder/ms-marco-MiniLM-L-6-v2"

  def serving_reranker() do
    repo = {:hf, System.get_env("AI_RERANK_MODEL", @default_rerank_model)}

    {:ok, model_info} = Bumblebee.load_model(repo)
    {:ok, tokenizer} = Bumblebee.load_tokenizer(repo)

    %Nx.Serving{} =
      Bumblebee.Text.cross_encoding(model_info, tokenizer,
        defn_options: [compiler: EXLA],
        compile: [batch_size: 10, sequence_length: 512]
      )
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

  @dialyzer {:no_return, monitor_transport_and_halt: 0}
  defp monitor_transport_and_halt do
    transport_name = Anubis.Server.Registry.transport_name(StdioMcp.MCPServer, :stdio)
    pid = await_pid(transport_name)

    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
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

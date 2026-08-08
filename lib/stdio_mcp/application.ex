defmodule StdioMcp.Application do
  @moduledoc false
  use Application

  require Logger

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
      ] ++ reranker_children() ++ mcp_children()

    opts = [strategy: :one_for_one, name: StdioMcp.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        if stdio_transport?(), do: spawn(&monitor_transport_and_halt/0)
        {:ok, pid}

      other ->
        other
    end
  end

  # Not every reranker on HuggingFace loads here: `Bumblebee.Text.cross_encoding`
  # needs an architecture Bumblebee implements with a sequence-classification
  # head, which rules out most of the current state of the art before quality
  # enters the picture. Checked 2026-08-06:
  #
  #   cross-encoder/ms-marco-MiniLM-L4-v2        OK   Bert, 19M   (default)
  #   cross-encoder/ms-marco-MiniLM-L6-v2        OK   Bert, 22M
  #   cross-encoder/ms-marco-MiniLM-L12-v2       OK   Bert, 33M
  #   cross-encoder/ms-marco-TinyBERT-L2-v2      OK   Bert, 4M
  #   cross-encoder/ms-marco-TinyBERT-L6         OK   Bert, 22M
  #   BAAI/bge-reranker-base                     OK   Roberta, 278M
  #   mixedbread-ai/mxbai-rerank-xsmall-v1       no   DebertaV2 unsupported
  #   jinaai/jina-reranker-v2-base-multilingual  no   custom arch, weights unreadable
  #
  # Note the repo ids were renamed upstream: `ms-marco-MiniLM-L-6-v2` now
  # redirects to `ms-marco-MiniLM-L6-v2`. The old form still resolves; the new
  # one is used here so nothing depends on a redirect.
  #
  # Capacity is not the axis. Measured across a 70x parameter range on the
  # 28-query eval, quality spans 0.03 of recall@5 — one query — while latency
  # spans 35x:
  #
  #   model             params   all r@5 / MRR   concept r@5   symbol MRR   ms
  #   TinyBERT-L2-v2      4M       0.93 / 0.81      0.88          1.00        69
  #   TinyBERT-L4        14M       0.93 / 0.79      0.88          1.00       229
  #   MiniLM-L4-v2       19M       0.96 / 0.81      0.94          1.00       294
  #   MiniLM-L6-v2       22M       0.96 / 0.82      0.94          1.00       414
  #   MiniLM-L12-v2      33M       0.93 / 0.81      0.88          1.00       772
  #   TinyBERT-L6        22M       0.96 / 0.73      0.94          0.90      1017
  #   bge-reranker-base 278M       0.93 / 0.78      0.88          1.00      1930
  #
  # TinyBERT-L6 is the one to avoid: 0.90 symbol MRR, the only model that fails
  # the case every other one gets perfect, and slower than MiniLM-L6. Among the
  # rest, if one is wanted, MiniLM-L4-v2: it matches L6 on every number at 70% of
  # the time, and it is the smallest that does not drop a query L6 keeps.
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
  # Off unless `AI_RERANK_MODEL` names a model, which is a judgement about the
  # *consumer* rather than about the models above. `search_docs` answers an LLM
  # that reads every row it is given before replying, so it does its own ranking
  # downstream and rank-within-the-payload is close to worthless; what it cannot
  # repair is a document that never arrives. Those are exactly the two columns
  # reranking trades between. End to end, 28 queries at top-5, rerank depth 10,
  # 3891 rows, MiniLM-L4-v2 on EMLX/Apple GPU:
  #
  #   slice          rrf                  rrf+rerank           rerank stage
  #   all (28)       0.96  MRR 0.75       0.96  MRR 0.78          +61ms
  #   concept (16)   0.94  MRR 0.63       0.94  MRR 0.62          +63ms
  #   symbol (12)    1.00  MRR 0.92       1.00  MRR 1.00          +63ms
  #
  # `recall@5` is identical in every slice, and `cand` is 1.00 throughout: the
  # stage cannot add a document, only reorder one already in the payload. That is
  # by construction, not luck.
  #
  # The headline +0.03 MRR is an average over two opposite effects. Symbol queries
  # saturate — twelve identifier queries all landing at rank 1 — while concept
  # queries gain nothing, and on this run come out 0.01 lower. On 12 and 16
  # queries those deltas are one or two documents moving a single rank, so read
  # the concept figure as "no gain" rather than as harm. Either way it is the
  # opposite of the intuition: the cross-encoder polishes the class that already
  # worked and leaves the weak class exactly where it was.
  #
  # Latency is backend-dependent and the column above is Apple silicon. The same
  # stage costs ~250ms under EXLA on CPU, which is what Linux sees — so total
  # search goes 29ms -> 90ms here, and roughly 46ms -> 294ms there. Other models
  # in the sweep have not been re-measured under EMLX.
  #
  # Skipping the serving also takes a ~100MB HuggingFace download and a compile
  # out of `Application.start/2` — they happened inside the window an MCP client
  # waits for the server to come up, so a cold machine's first connection could
  # time out and look broken.
  #
  # The stage is kept, not deleted: a consumer that reads only the first result
  # wants it back, and it is one env var away. `Reranker.rerank/2` already gates
  # on the serving being registered, so not starting it is the entire switch.
  defp reranker_children do
    case Application.get_env(:stdio_mcp, :ai_rerank_model) do
      nil -> []
      model -> reranker_child(model)
    end
  end

  # A name that does not load disables reranking; it does not stop the server.
  # This used to be `{:ok, x} = Bumblebee.load_model(repo)`, so a typo in
  # `AI_RERANK_MODEL` raised a MatchError *inside* `start/2` and the application
  # never started — the MCP client saw a server that would not come up, with the
  # reason on a stderr stream it discards. That is the loudest possible failure
  # for the least important stage: every other part of the pipeline degrades (no
  # embedding gives FTS-only, no serving gives fused order), and reranking is the
  # one component whose absence costs no recall at all.
  #
  # Realistic trigger, not a hypothetical: `ms-marco-TinyBERT-L-4-v2` appears in
  # circulating model lists and does not exist in either naming scheme — the `-v2`
  # suffix belongs to the L2 line, not L4. HuggingFace 401s it.
  defp reranker_child(model) do
    case serving_reranker(model) do
      {:ok, serving} ->
        [{Nx.Serving, serving: serving, name: Rerank}]

      {:error, reason} ->
        # Logger rather than a direct write to stderr, which is what
        # `runtime.exs` uses for its config warnings: the MCP client discards
        # stderr, so the one message explaining why reranking is off would be
        # invisible in precisely the session where it matters. Logger also
        # reaches `MCP_LOG_FILE`.
        #
        # `error`, not `warning`: `config.exs` sets `level: :error`, so anything
        # below it is discarded before a handler sees it — a warning here would
        # have been as invisible as the stderr write it replaced. The level is
        # also honest. The operator asked for a reranker and did not get one.
        Logger.error(
          "AI_RERANK_MODEL=#{model} did not load (#{inspect(reason)}) — " <>
            "starting without reranking; searches return the fused RRF order"
        )

        []
    end
  end

  @spec serving_reranker(String.t()) :: {:ok, Nx.Serving.t()} | {:error, term()}
  def serving_reranker(model) do
    repo = {:hf, model}

    with {:ok, model_info} <- Bumblebee.load_model(repo),
         {:ok, tokenizer} <- Bumblebee.load_tokenizer(repo) do
      %Nx.Serving{} =
        serving =
        Bumblebee.Text.cross_encoding(model_info, tokenizer,
          # The `[]` default is load-bearing. `defn_options: nil` raises
          # FunctionClauseError in `Nx.Serving.new/2`, and nothing here rescues
          # it — the raise escapes `serving_reranker/1` past the `{:ok, _}` /
          # `{:error, _}` case in `reranker_child/1` and takes down
          # `Application.start/2`, so the server never boots. That is the same
          # failure the model-loading comment above describes, reachable again
          # through config: any environment where `:default_defn_options` is
          # unset turns AI_RERANK_MODEL into "the MCP server will not start".
          defn_options: Application.get_env(:nx, :default_defn_options, []),
          compile: [batch_size: 10, sequence_length: 512]
        )

      {:ok, serving}
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

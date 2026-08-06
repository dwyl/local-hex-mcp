defmodule StdioMcp.Docs.IngestionJob do
  @moduledoc """
  Single-flight coordination for package ingestion.

  Exactly one job runs per `{owner, package, version}` key no matter how many
  callers ask for it. Every caller waits on that one job and receives the same
  result, so an impatient retry attaches to the work already in progress instead
  of launching a competing download and re-embedding the same package.

  A caller that stops waiting does **not** cancel the job. The job runs under
  `StdioMcp.TaskSupervisor` and is unlinked from whoever asked for it, so it
  survives the request returning; the next request either finds the rows in the
  database or attaches to the still-running job and reports its progress.
  """
  require Logger

  @jobs StdioMcp.IngestionRegistry
  @waiters StdioMcp.IngestionWaiters
  @supervisor StdioMcp.TaskSupervisor

  @typedoc "What `run/5` reports back to a caller."
  @type outcome :: {:ok, term()} | {:timeout, map()} | {:error, term()}

  @doc """
  Runs `work` under the key `{owner, package, version}`, or joins the job
  already running under that key, and waits up to `timeout` for its result.

  Returns `{:ok, result}` with whatever `work` returned, `{:timeout, progress}`
  while the job keeps running, or `{:error, reason}` if the job died.
  """
  @spec run(module(), String.t(), String.t(), timeout(), (-> term())) :: outcome()
  def run(owner, package, version, timeout, work) when is_function(work, 0) do
    key = {owner, package, version}

    # Subscribing *before* the job is started is what makes this race-free: the
    # job cannot finish and dispatch its result before this process is on the
    # waiter list, so no completion can slip through unseen.
    {:ok, _} = Registry.register(@waiters, key, nil)

    try do
      case ensure_started(key, work) do
        {:ok, pid} -> wait(key, pid, timeout)
        {:error, reason} -> {:error, {:job_not_started, reason}}
      end
    after
      Registry.unregister(@waiters, key)
    end
  end

  @doc """
  Records the stage of the job running in this process, for the progress notice
  a timed-out caller receives. Called from inside `work`; a no-op elsewhere.
  """
  @spec stage(atom() | String.t()) :: :ok
  def stage(stage) when is_atom(stage) or is_binary(stage) do
    case Process.get(:ingestion_job_key) do
      nil ->
        :ok

      key ->
        Registry.update_value(@jobs, key, &Map.put(&1, :stage, stage))
        :ok
    end
  end

  @doc "Progress of the job under `key`, or an empty snapshot if none is running."
  @spec progress({module(), String.t(), String.t()}) :: map()
  def progress(key) do
    case Registry.lookup(@jobs, key) do
      [{_pid, %{started_at: started_at} = meta}] ->
        Map.put(meta, :elapsed_ms, System.monotonic_time(:millisecond) - started_at)

      _ ->
        %{stage: :unknown, elapsed_ms: nil}
    end
  end

  # -- Starting ---------------------------------------------------------------

  @spec ensure_started(term(), term()) :: {:ok, pid} | {:error, term()}
  defp ensure_started(key, work) do
    case Registry.lookup(@jobs, key) do
      [{pid, _meta}] ->
        {:ok, pid}

      [] ->
        # Two callers can both find nothing and both start a child. The loser
        # fails to register and exits immediately; `wait/3` notices the early
        # exit and re-attaches to whichever child won the key.
        Task.Supervisor.start_child(@supervisor, fn -> run_job(key, work) end)
    end
  end

  defp run_job(key, work) do
    meta = %{started_at: System.monotonic_time(:millisecond), stage: :starting}

    case Registry.register(@jobs, key, meta) do
      {:ok, _} ->
        Process.put(:ingestion_job_key, key)
        :ok = broadcast(key, execute(key, work))

      {:error, {:already_registered, _}} ->
        :ok
    end
  end

  # A raise inside `work` must still reach the waiters: letting the job die
  # silently would leave every caller waiting out the full timeout for a result
  # that is never coming.
  defp execute(key, work) do
    {:ok, work.()}
  catch
    kind, reason ->
      Logger.error(
        "[IngestionJob] #{inspect(key)} failed: #{Exception.format(kind, reason, __STACKTRACE__)}"
      )

      {:error, {kind, reason}}
  end

  defp broadcast(key, result) do
    Registry.dispatch(@waiters, key, fn entries ->
      :ok = Enum.each(entries, fn {pid, _} -> send(pid, {:ingestion_done, key, result}) end)
    end)
  end

  # -- Waiting ----------------------------------------------------------------

  defp wait(key, pid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(key, pid, Process.monitor(pid), deadline)
  end

  defp do_wait(key, pid, ref, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:ingestion_done, ^key, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        case Registry.lookup(@jobs, key) do
          # This process lost the registration race; the winner owns the key and
          # is still working, so wait on that one instead of reporting failure.
          [{owner, _meta}] when owner != pid ->
            do_wait(key, owner, Process.monitor(owner), deadline)

          _ ->
            drain(key, reason)
        end
    after
      remaining ->
        Process.demonitor(ref, [:flush])
        {:timeout, progress(key)}
    end
  end

  # The job dispatches its result and only then exits, and messages from one
  # process arrive in order, so a result sent just before the exit is already in
  # the mailbox behind the :DOWN.
  defp drain(key, reason) do
    receive do
      {:ingestion_done, ^key, result} -> result
    after
      0 -> {:error, {:job_exited, reason}}
    end
  end
end

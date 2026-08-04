defmodule StdioMcp.Docs.RepairBudget do
  @moduledoc """
  Caps how often a package may be re-ingested to repair rows whose embeddings are
  missing.

  Rows with a nil embedding are invisible to vector search, so re-ingesting to
  fix them is worth attempting — but only a bounded number of times. Repair was
  previously automatic and unbounded, and a package that *cannot* be re-embedded
  (rate limit, missing API key) re-downloaded its tarball and failed again on
  every single search, never converging. Measured on anubis_mcp: 315 nil rows,
  429 on every attempt.

  An `Agent` rather than a GenServer-owned ETS table: the counter is read at most
  once per search, so there is no read throughput to protect, and `use Agent`
  supplies `child_spec/1`.

  State is deliberately not persisted. A server restart clears the budget, which
  means a transient outage cannot disable repair permanently — and a restart is
  already how new code is picked up here.
  """
  use Agent

  @max_attempts 2

  @type key :: {package :: String.t(), version :: String.t()}

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "Whether another repair attempt is allowed for this package/version."
  @spec allow?(String.t(), String.t()) :: boolean()
  def allow?(package, version), do: attempts(package, version) < @max_attempts

  @doc "Records an attempt. Call before ingesting, so a crash still counts."
  @spec record_attempt(String.t(), String.t()) :: :ok
  def record_attempt(package, version) do
    Agent.update(__MODULE__, &Map.update(&1, {package, version}, 1, fn n -> n + 1 end))
  end

  @doc "Forgets the attempts for a package/version, after a repair succeeded."
  @spec clear(String.t(), String.t()) :: :ok
  def clear(package, version) do
    Agent.update(__MODULE__, &Map.delete(&1, {package, version}))
  end

  @spec attempts(String.t(), String.t()) :: non_neg_integer()
  def attempts(package, version) do
    Agent.get(__MODULE__, &Map.get(&1, {package, version}, 0))
  end

  @doc "How many attempts are permitted before repair gives up."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts
end

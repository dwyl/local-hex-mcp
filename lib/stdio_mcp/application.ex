defmodule StdioMcp.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Redirect Erlang logger to stderr so stdout stays completely clean for JSON-RPC
    :logger.update_handler_config(:default, :config, %{type: :standard_error})

    # Attach Telemetry handler to record AI token usage into SQLite
    StdioMcp.Telemetry.attach()

    provider = Application.get_env(:stdio_mcp, :ai_api_url, "https://api.mistral.ai")

    children =
      [
        StdioMcp.Repo,
        {Finch, name: StdioMcp.Finch, pools: %{provider => [size: 10]}},
        {Registry, keys: :unique, name: StdioMcp.IngestionRegistry},
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

  # The stdio transport takes over stdin/stdout for JSON-RPC, and
  # `monitor_transport_and_halt/0` halts the VM as soon as it sees EOF. Started
  # unconditionally, that makes every other way of booting the app unusable:
  # `mix run` produces no output and exits 0 before the script finishes, so
  # seeds and maintenance tasks silently do nothing.
  #
  # `mix mcp.server` sets MCP_TRANSPORT itself, so client configs need no change.
  defp mcp_children do
    if stdio_transport?() do
      [{StdioMcp.MCPServer, transport: :stdio}]
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

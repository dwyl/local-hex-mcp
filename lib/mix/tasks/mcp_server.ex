defmodule Mix.Tasks.Mcp.Server do
  @moduledoc "Starts the StdioMcp server over stdio transport."
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.shell(Mix.Shell.Quiet)
    :logger.update_handler_config(:default, :config, %{type: :standard_error})
    Mix.Task.run("app.start")
    Process.sleep(:infinity)
  end
end

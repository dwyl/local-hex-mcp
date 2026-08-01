defmodule StdioMcp.Telemetry do
  @moduledoc "Listens to :telemetry AI events and persists token consumption to SQLite."

  alias StdioMcp.{Repo, TokenUsageLog}

  def attach do
    :telemetry.attach(
      "stdio-mcp-ai-token-persister",
      [:stdio_mcp, :ai, :token_usage],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event(_event_name, measurements, metadata, _config) do
    Task.Supervisor.start_child(StdioMcp.TaskSupervisor, fn ->
      %TokenUsageLog{}
      |> TokenUsageLog.changeset(%{
        model: to_string(metadata[:model]),
        type: to_string(metadata[:type]),
        prompt_tokens: measurements[:prompt_tokens] || 0,
        completion_tokens: measurements[:completion_tokens] || 0,
        total_tokens: measurements[:total_tokens] || 0
      })
      |> Repo.insert()
    end)
  end
end

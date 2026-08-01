defmodule StdioMcp.AI.Mistral do
  @moduledoc "Backward-compatibility alias for StdioMcp.AI.Client."

  defdelegate small_model, to: StdioMcp.AI.Client
  defdelegate large_model, to: StdioMcp.AI.Client
  defdelegate embed_model, to: StdioMcp.AI.Client
  defdelegate api_key, to: StdioMcp.AI.Client
  defdelegate embed(text), to: StdioMcp.AI.Client
  defdelegate embed_batch(texts), to: StdioMcp.AI.Client
  defdelegate chat(messages), to: StdioMcp.AI.Client
  defdelegate chat(messages, tools), to: StdioMcp.AI.Client
  defdelegate chat(messages, tools, opts), to: StdioMcp.AI.Client
end

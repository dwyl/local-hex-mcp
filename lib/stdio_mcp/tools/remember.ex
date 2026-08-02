defmodule StdioMcp.Tools.Remember do
  @moduledoc "Save a technical learning or pain point to the knowledge base."

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias StdioMcp.AI.Client
  alias StdioMcp.Memory

  schema do
    field(:text, :string,
      required: true,
      description:
        "Detailed description of the lesson learned, bug fix, or pattern to store in the knowledge base."
    )
  end

  @impl true
  def execute(%{text: text}, frame) do
    reply = if Client.memory_enabled?(), do: submit(text), else: disabled_reply()
    {:reply, Response.text(Response.tool(), Jason.encode!(reply)), frame}
  end

  # The decision record is opened before the task is spawned, so the caller
  # always has a request_id to look up: curation runs asynchronously and may
  # discard or redirect the submission, outcomes that write nothing to the
  # knowledge table and would otherwise be indistinguishable from a save.
  defp submit(text) do
    request_id = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    case Memory.open_decision(request_id, text) do
      {:ok, _} ->
        Task.Supervisor.start_child(StdioMcp.TaskSupervisor, fn ->
          Memory.process_remember(text, request_id)
        end)

        %{
          accepted: true,
          status: "processing",
          request_id: request_id,
          note:
            "Curation runs asynchronously and may discard, append, merge, replace or deprecate. " <>
              "Look up this request_id to see what was actually done."
        }

      {:error, _reason} ->
        %{accepted: false, status: "failed", detail: "could not record request"}
    end
  end

  defp disabled_reply do
    %{
      accepted: false,
      status: "disabled",
      reason: "Knowledge memory curation requires AI_API_KEY to be set for classification."
    }
  end
end

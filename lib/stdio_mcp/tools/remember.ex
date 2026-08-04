defmodule StdioMcp.Tools.Remember do
  @moduledoc """
  Save a technical learning or pain point to this project's local knowledge base,
  retrievable later with `recall`.

  Call it **after** a fix, and only when the fix is worth recording:

    * **two or more attempts** — the first edit did not work. One-attempt fixes
      (typos, syntax errors, missing imports) are noise and dilute the base.
    * **cross-layer causes** — the problem spanned two or more layers, e.g.
      reverse proxy plus application, container networking plus database, config
      provider plus release.
    * **version quirks** — undocumented behaviour or a version constraint in a
      dependency.

  Record *why* it happened and *how to apply* the lesson, not only what changed:
  an entry that cannot be acted on next time is not worth storing. Curation runs
  asynchronously and may merge, append to, replace or discard what you submit, so
  the stored result can differ from the text sent.
  """

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

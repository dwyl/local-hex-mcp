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
    field(:texts, {:list, :string},
      required: true,
      description:
        "One or more lessons to store. Pass every learning from a session in a single call rather than calling this tool repeatedly: an Anubis session holds one request in flight and queues the rest, so repeated calls buy no parallelism and cost a model turn each. A single lesson is a one-element list."
    )
  end

  @impl true
  def execute(%{texts: texts}, frame) do
    reply = if Client.memory_enabled?(), do: submit_all(texts), else: disabled_reply()
    {:reply, Response.text(Response.tool(), Jason.encode!(reply)), frame}
  rescue
    e ->
      require Logger

      Logger.error(
        "[Remember] Tool execution failed:\n#{Exception.format(:error, e, __STACKTRACE__)}"
      )

      {:reply, Response.text(Response.tool(), "Remember failed: #{Exception.message(e)}"), frame}
  end

  # Every decision record is opened *before* anything is spawned, so the caller
  # leaves with a request_id for each submission even if curation later discards
  # it — an outcome that writes nothing to the knowledge table and would
  # otherwise be indistinguishable from a save.
  #
  # One task for the whole batch, processing in order, rather than one task per
  # entry. Each entry costs an embedding call plus a chat completion, and firing
  # them concurrently is the reliable way to collect 429s from a provider that
  # rate-limits on requests per second. Nothing waits on this: the reply returns
  # as soon as the records exist.
  defp submit_all([]), do: %{accepted: 0, status: "empty", detail: "no texts given"}

  defp submit_all(texts) do
    submissions = Enum.map(texts, &open/1)
    {opened, failed} = Enum.split_with(submissions, &match?({:ok, _, _}, &1))

    queued = Enum.map(opened, fn {:ok, request_id, text} -> {request_id, text} end)

    if queued != [] do
      Task.Supervisor.start_child(StdioMcp.TaskSupervisor, fn ->
        Enum.each(queued, fn {request_id, text} ->
          Memory.process_remember(text, request_id)
        end)
      end)
    end

    %{
      accepted: length(queued),
      rejected: length(failed),
      status: "processing",
      request_ids: Enum.map(queued, &elem(&1, 0)),
      note:
        "Curation runs asynchronously, in order, and may discard, append, merge, replace or " <>
          "deprecate any entry. Look up a request_id to see what was actually done with it."
    }
  end

  defp open(text) do
    request_id = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    case Memory.open_decision(request_id, text) do
      {:ok, _} -> {:ok, request_id, text}
      {:error, reason} -> {:error, reason}
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

defmodule StdioMcp.Tools.GetTokenUsage do
  @moduledoc "Get total AI token consumption statistics stored in the database."

  use Anubis.Server.Component, type: :tool
  import Ecto.Query
  alias Anubis.Server.Response
  alias StdioMcp.{Repo, TokenUsageLog}

  schema do
    field(:model, :string, description: "Optional filter by model name (e.g. 'mistral-embed', 'mistral-small-latest').")
    field(:from, :string, description: "Optional start date filter (YYYY-MM-DD or ISO8601 string, e.g. '2026-08-01').")
    field(:until, :string, description: "Optional end date filter (YYYY-MM-DD or ISO8601 string, e.g. '2026-08-31').")
  end

  @impl true
  def execute(params, frame) do
    model_filter = params[:model]
    from_filter = params[:from]
    until_filter = params[:until]

    query = from t in TokenUsageLog, select: t

    query =
      if model_filter && model_filter != "" do
        from t in query, where: t.model == ^model_filter
      else
        query
      end

    query =
      if from_filter && from_filter != "" do
        case parse_date_start(from_filter) do
          {:ok, dt} -> from t in query, where: t.inserted_at >= ^dt
          _ -> query
        end
      else
        query
      end

    query =
      if until_filter && until_filter != "" do
        case parse_date_end(until_filter) do
          {:ok, dt} -> from t in query, where: t.inserted_at <= ^dt
          _ -> query
        end
      else
        query
      end

    logs = Repo.all(query)

    total_prompt = Enum.sum_by(logs, & &1.prompt_tokens)
    total_completion = Enum.sum_by(logs, & &1.completion_tokens)
    total_tokens = Enum.sum_by(logs, & &1.total_tokens)

    by_model =
      logs
      |> Enum.group_by(& &1.model)
      |> Map.new(fn {model, list} ->
        {model,
         %{
           requests: length(list),
           prompt_tokens: Enum.sum_by(list, & &1.prompt_tokens),
           completion_tokens: Enum.sum_by(list, & &1.completion_tokens),
           total_tokens: Enum.sum_by(list, & &1.total_tokens)
         }}
      end)

    result = %{
      total_requests: length(logs),
      total_tokens: total_tokens,
      total_prompt_tokens: total_prompt,
      total_completion_tokens: total_completion,
      period: %{
        from: from_filter || "beginning",
        until: until_filter || "now"
      },
      by_model: by_model
    }

    {:reply, Response.text(Response.tool(), Jason.encode!(result)), frame}
  rescue
    e ->
      {:reply, Response.text(Response.tool(), "Get token usage failed: #{Exception.message(e)}"), frame}
  end

  defp parse_date_start(str) do
    case NaiveDateTime.from_iso8601(str) do
      {:ok, dt} ->
        {:ok, dt}

      _ ->
        case Date.from_iso8601(str) do
          {:ok, d} -> {:ok, NaiveDateTime.new!(d, ~T[00:00:00])}
          _ -> :error
        end
    end
  end

  defp parse_date_end(str) do
    case NaiveDateTime.from_iso8601(str) do
      {:ok, dt} ->
        {:ok, dt}

      _ ->
        case Date.from_iso8601(str) do
          {:ok, d} -> {:ok, NaiveDateTime.new!(d, ~T[23:59:59])}
          _ -> :error
        end
    end
  end
end

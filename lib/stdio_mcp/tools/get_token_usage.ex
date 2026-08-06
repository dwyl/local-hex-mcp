defmodule StdioMcp.Tools.GetTokenUsage do
  @moduledoc """
  Report AI token consumption recorded in the local database, broken down by
  model and request type.

  Useful before or after a large ingestion — `search_docs` with `refresh: true`
  on a big package embeds every document — and for answering "what has this cost
  so far". Totals are cumulative and persist across restarts.

  Optional `model`, `from` and `until` (e.g. `"2026-08-01"`) narrow the range; an
  unparseable date is ignored rather than rejected.
  """

  use Anubis.Server.Component, type: :tool
  import Ecto.Query
  alias Anubis.Server.Response
  alias StdioMcp.{Repo, TokenUsageLog}

  schema do
    field(:model, :string,
      description: "Optional filter by model name (e.g. 'mistral-embed', 'mistral-small-latest')."
    )

    field(:from, :string,
      description: "Optional start date filter (YYYY-MM-DD or ISO8601 string, e.g. '2026-08-01')."
    )

    field(:until, :string,
      description: "Optional end date filter (YYYY-MM-DD or ISO8601 string, e.g. '2026-08-31')."
    )
  end

  defp filter_by_model(query, model) when is_binary(model) and model != "" do
    from(t in query, where: t.model == ^model)
  end

  defp filter_by_model(query, _model), do: query

  # An unparseable date is ignored rather than rejected: the filter is a
  # convenience and a bad value should not fail the whole query.
  defp filter_from(query, value) when is_binary(value) and value != "" do
    case parse_date_start(value) do
      {:ok, dt} -> from(t in query, where: t.inserted_at >= ^dt)
      _ -> query
    end
  end

  defp filter_from(query, _value), do: query

  defp filter_until(query, value) when is_binary(value) and value != "" do
    case parse_date_end(value) do
      {:ok, dt} -> from(t in query, where: t.inserted_at <= ^dt)
      _ -> query
    end
  end

  defp filter_until(query, _value), do: query

  @impl true
  def execute(params, frame) do
    model_filter = params[:model]
    from_filter = params[:from]
    until_filter = params[:until]

    logs =
      from(t in TokenUsageLog, select: t)
      |> filter_by_model(model_filter)
      |> filter_from(from_filter)
      |> filter_until(until_filter)
      |> Repo.all()

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
      require Logger
      Logger.error("[GetTokenUsage] Tool execution failed:\n#{Exception.format(:error, e, __STACKTRACE__)}")

      {:reply, Response.text(Response.tool(), "Get token usage failed: #{Exception.message(e)}"),
       frame}
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

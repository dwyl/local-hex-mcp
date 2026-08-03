defmodule StdioMcp.AI.Client do
  @moduledoc "Generic REST client for embeddings and chat completions across Cloud AI providers."

  def api_url do
    System.get_env("AI_API_URL") ||
      Application.get_env(:stdio_mcp, :ai_api_url, "https://api.mistral.ai/v1")
  end

  def api_key do
    System.get_env("AI_API_KEY") ||
      System.get_env("MISTRAL_API_KEY") ||
      Application.get_env(:stdio_mcp, :ai_api_key)
  end

  def small_model do
    System.get_env("AI_CHAT_MODEL_SMALL") ||
      Application.get_env(:stdio_mcp, :ai_chat_model_small, "mistral-small-latest")
  end

  def large_model do
    System.get_env("AI_CHAT_MODEL_LARGE") ||
      Application.get_env(:stdio_mcp, :ai_chat_model_large, "mistral-medium-latest")
  end

  def embed_model do
    System.get_env("AI_EMBED_MODEL") ||
      Application.get_env(:stdio_mcp, :ai_embed_model, "mistral-embed")
  end

  def memory_enabled? do
    key = api_key()
    is_binary(key) and key != "" and is_binary(small_model()) and small_model() != ""
  end

  def embed(text) when is_binary(text) do
    case embed_batch([text]) do
      {:ok, [vector]} -> {:ok, vector}
      {:error, reason} -> {:error, reason}
    end
  end

  def embed_batch(texts) when is_list(texts) do
    key = api_key()

    if is_nil(key) or key == "" do
      {:error, :missing_api_key}
    else
      base_url = String.trim_trailing(api_url(), "/")
      url = "#{base_url}/embeddings"
      model = embed_model()

      headers = [
        {"authorization", "Bearer #{key}"},
        {"content-type", "application/json"}
      ]

      body = %{model: model, input: texts}

      # A batch of 50 inputs regularly outruns Req's 15s default receive_timeout,
      # and a timeout here surfaces as a failed batch that aborts the ingest.
      case Req.post(url,
             json: body,
             headers: headers,
             receive_timeout: 60_000,
             finch: [name: StdioMcp.Finch]
           ) do
        {:ok, %{status: 200, body: %{"data" => data} = resp_body}} ->
          emit_usage(resp_body["usage"], model, :embedding)
          vectors = Enum.map(data, & &1["embedding"])
          {:ok, vectors}

        # Carries the server's Retry-After (in ms) rather than a message string,
        # so a caller retrying a batch can wait exactly as long as it is told to
        # instead of guessing. `nil` when the header is absent or unparsable.
        {:ok, %{status: 429} = resp} ->
          {:error, {429, retry_after_ms(resp)}}

        {:ok, %{status: status, body: err}} ->
          {:error, {status, err}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Retry-After is defined as either delay-seconds or an HTTP date; only the
  # numeric form is handled, and anything else falls back to the caller's own
  # backoff rather than guessing at a date format.
  defp retry_after_ms(resp) do
    case Req.Response.get_header(resp, "retry-after") do
      [value | _] ->
        case Integer.parse(String.trim(value)) do
          {seconds, ""} when seconds >= 0 -> seconds * 1000
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def chat(messages, _tools \\ [], opts \\ []) do
    key = api_key()

    if is_nil(key) or key == "" do
      {:error, :missing_api_key}
    else
      base_url = String.trim_trailing(api_url(), "/")
      url = "#{base_url}/chat/completions"
      model = Keyword.get(opts, :model, small_model())

      headers = [
        {"authorization", "Bearer #{key}"},
        {"content-type", "application/json"}
      ]

      body =
        %{model: model, messages: messages, temperature: 0.2}
        |> maybe_json_mode(opts)

      case Req.post(url,
             json: body,
             headers: headers,
             receive_timeout: 90_000,
             finch: [name: StdioMcp.Finch]
           ) do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => msg} | _]} = resp_body}} ->
          emit_usage(resp_body["usage"], model, :chat)
          {:ok, msg}

        {:ok, %{status: status, body: err}} ->
          {:error, {status, err}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Supports both generic JSON object mode (opts: [json: true]) and strict JSON schema mode
  # (opts: [json_schema: schema, schema_name: "name", strict: true]).
  defp maybe_json_mode(body, opts) do
    cond do
      schema = Keyword.get(opts, :json_schema) ->
        Map.put(body, :response_format, %{
          type: "json_schema",
          json_schema: %{
            name: Keyword.get(opts, :schema_name, "response_schema"),
            strict: Keyword.get(opts, :strict, true),
            schema: schema
          }
        })

      Keyword.get(opts, :json, false) ->
        Map.put(body, :response_format, %{type: "json_object"})

      true ->
        body
    end
  end

  defp emit_usage(nil, _model, _type), do: :ok

  defp emit_usage(usage, model, type) do
    :telemetry.execute(
      [:stdio_mcp, :ai, :token_usage],
      %{
        prompt_tokens: usage["prompt_tokens"] || usage["total_tokens"] || 0,
        completion_tokens: usage["completion_tokens"] || 0,
        total_tokens: usage["total_tokens"] || 0
      },
      %{model: model, type: type}
    )
  end
end

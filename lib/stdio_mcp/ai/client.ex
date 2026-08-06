defmodule StdioMcp.AI.Client do
  @moduledoc "Generic REST client for embeddings and chat completions across Cloud AI providers."

  # Every one of these read `System.get_env/1` first and fell back to the app
  # env, which made `config/runtime.exs` look like the place settings are
  # resolved while it was actually only the *second* place — and the two did not
  # agree. `runtime.exs` used to accept `MISTRAL_MODEL_EMBED` as an alternative
  # spelling of `AI_EMBED_MODEL`, while this module only ever read the latter —
  # so setting the legacy name on the command line was silently ignored here
  # while appearing to take effect everywhere else. Both the second name and the
  # second resolution point are gone.
  #
  # One resolution point now: `runtime.exs` reads the environment, this reads the
  # app env. Still runtime, so a restart is all a new value needs.
  def api_url, do: Application.get_env(:stdio_mcp, :ai_api_url, "https://api.mistral.ai/v1")

  def api_key, do: Application.get_env(:stdio_mcp, :ai_api_key)

  def small_model,
    do: Application.get_env(:stdio_mcp, :ai_chat_model_small, "mistral-small-latest")

  def large_model,
    do: Application.get_env(:stdio_mcp, :ai_chat_model_large, "mistral-medium-latest")

  def embed_model, do: Application.get_env(:stdio_mcp, :ai_embed_model, "mistral-embed")

  @spec memory_enabled?() :: boolean()
  def memory_enabled? do
    key = api_key()
    is_binary(key) and key != "" and is_binary(small_model()) and small_model() != ""
  end

  @typedoc """
  Every failure the provider calls can produce.

  Worth spelling out rather than leaving as `any()`: `{429, _}` carries the
  server's own `Retry-After` so a caller can wait exactly as long as it is told
  instead of guessing, and `{400, _}` is how a token-limit rejection arrives,
  which `TarballIngestion` bisects on rather than failing. A caller that cannot
  see those in the spec will not handle them.
  """
  @type error ::
          :missing_api_key
          | {429, retry_after_ms :: non_neg_integer() | nil}
          | {status :: 100..599, detail :: term()}
          | Exception.t()

  @spec embed(binary()) :: {:ok, [float()]} | {:error, error()}
  def embed(text) when is_binary(text) do
    case embed_batch([text]) do
      {:ok, [vector]} -> {:ok, vector}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec embed_batch([binary()]) :: {:ok, [[float()]]} | {:error, error()}
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
        {:ok, %Req.Response{status: 200, body: %{"data" => data} = resp_body}} ->
          emit_usage(resp_body["usage"], model, :embedding)
          vectors = Enum.map(data, & &1["embedding"])
          {:ok, vectors}

        # Carries the server's Retry-After (in ms) rather than a message string,
        # so a caller retrying a batch can wait exactly as long as it is told to
        # instead of guessing. `nil` when the header is absent or unparsable.
        {:ok, %Req.Response{status: 429} = resp} ->
          {:error, {429, retry_after_ms(resp)}}

        {:ok, %Req.Response{status: status, body: err}} ->
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

  @spec chat([map()], list(), keyword()) :: {:ok, map()} | {:error, error()}
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
  @spec maybe_json_mode(map(), term()) :: map()
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

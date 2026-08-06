defmodule StdioMcp.Docs.Reranker do
  @moduledoc """
  Cross-encoder rescoring of fused candidates.

  Unlike the embedding arm, which compares two vectors computed independently,
  a cross-encoder reads the query and the document *together* and emits one
  relevance logit. That joint attention is what fixes queries where the right
  answer shares no vocabulary with the question: `"prevent interception of the
  authorization code"` moves from RRF rank 11 to rank 1 against boruta's PKCE
  documentation.

  ## `sequence_length` is the whole game

  The serving is compiled at a fixed `sequence_length` (see
  `StdioMcp.Application.serving_reranker/0`) and silently truncates the pair to
  it. At 128 tokens — roughly 400 characters — a symbol query still works,
  because the identifier is in the header prepended below, while a conceptual
  answer usually sits deeper in the chunk and is never seen. Measured on the
  26-query eval, reranking at 128 scored **worse than not reranking at all**
  (recall@5 0.88 against the un-reranked 0.92); at 512 it scores 1.00.

  A stage that truncates its input cannot report that it did, which is why this
  looked for a long time like a property of the model. It was not: bigger models
  score worse here (`bge-reranker-base`, 278M, at 0.78 MRR against MiniLM-L-6's
  0.82, and five times slower).

  ## Failure is degradation, never an error

  Reranking is a quality stage on top of a working search. If the serving is not
  running, or returns a shape this does not recognise, the fused order is
  returned unchanged — the caller gets RRF results rather than an exception.
  """

  require Logger

  @serving Rerank

  # What is scored is not what is returned. The reranker only has to judge
  # relevance, so it gets a deliberate prefix of the chunk rather than an
  # accidental one; the caller still receives the whole document.
  @max_chars 1500

  @doc "True when the serving process is running and can be called."
  @spec available?() :: boolean()
  def available?, do: is_pid(Process.whereis(@serving))

  @doc """
  Reorders `docs` by cross-encoder relevance to `query`.

  Returns the input order on any failure.

  Documents come first because they are what is being transformed, and this sits
  at the end of a pipe in both callers. Written query-first it reads better in
  isolation and silently binds the wrong way round when piped — the same mistake
  cost an afternoon in `SectionChunker.prepend_heading/2`.
  """
  @spec rerank([struct()], String.t()) :: [struct()]
  def rerank([], _query), do: []

  def rerank(docs, query) do
    if available?() do
      score_and_sort(query, docs)
    else
      docs
    end
  end

  defp score_and_sort(query, docs) do
    pairs = Enum.map(docs, &{query, text(&1)})

    case Nx.Serving.batched_run(@serving, pairs) do
      results ->
        case scores(results, length(pairs)) do
          {:ok, scores} ->
            scores
            |> Enum.zip(docs)
            |> Enum.sort_by(fn {score, _doc} -> -score end)
            |> Enum.map(fn {_score, doc} -> doc end)

          :error ->
            Logger.warning(
              "[Reranker] unrecognised serving output: " <>
                inspect(results, limit: 3, printable_limit: 120)
            )

            docs
        end
    end
  rescue
    e ->
      Logger.warning("[Reranker] scoring failed, keeping fused order: #{Exception.message(e)}")
      docs
  end

  # A short header rather than the full breadcrumb used for embedding: at the
  # compiled sequence length every token spent naming the package is a token not
  # spent on the text being judged.
  defp text(doc) do
    header =
      [doc.module, doc.function]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(".")

    body = doc.content |> to_string() |> String.slice(0, @max_chars)

    case header do
      "" -> body
      header -> header <> "\n\n" <> body
    end
  end

  # Bumblebee's cross-encoding output shape has moved between versions, so the
  # shapes are matched explicitly. Guessing one and taking the wrong element of a
  # pair would invert the ranking silently, which is worse than not reranking.
  defp scores(results, count) when is_list(results) and length(results) == count do
    Enum.reduce_while(results, {:ok, []}, fn result, {:ok, acc} ->
      case score(result) do
        {:ok, score} -> {:cont, {:ok, [score | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp scores(%{results: results}, count), do: scores(results, count)
  defp scores(%{predictions: predictions}, count), do: scores(predictions, count)
  defp scores(_other, _count), do: :error

  defp score(%{score: score}) when is_number(score), do: {:ok, score}
  defp score(%{results: [%{score: score} | _]}) when is_number(score), do: {:ok, score}
  defp score(%{predictions: [%{score: score} | _]}) when is_number(score), do: {:ok, score}
  defp score(score) when is_number(score), do: {:ok, score}
  defp score(_other), do: :error
end

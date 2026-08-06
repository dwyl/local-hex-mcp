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

  # How much authority the cross-encoder gets, via AI_RERANK_STRATEGY:
  #
  #   fused  (default) — reciprocal-rank fusion of the retrieval order with the
  #                      reranked one. The cross-encoder can move a document but
  #                      not overrule retrieval outright.
  #   pure             — cross-encoder ordering wins.
  #   gated            — keep retrieval order when the best score is negative.
  #
  # Measured on the 26-query eval, same corpus:
  #
  #   strategy   all r@5   all MRR   concept r@5
  #   pure          0.92      0.78          0.86
  #   gated         0.92      0.77          0.86
  #   fused         0.96      0.78          0.93
  #
  # The case that decides it: "prevent interception of the authorization code on
  # a public client" against boruta. All three retrieval arms put the PKCE guide
  # at rank 1; the cross-encoder drops it to 8, preferring `Boruta.Oauth.Client.t/0`
  # — a typespec listing `pkce: boolean()` among thirty fields. It is not wrong
  # to dislike the guide, which is a how-to that never explains *why* PKCE exists
  # (every score in that pool is negative, meaning "nothing here answers this").
  # But when the bi-encoder has bridged a gap the cross-encoder cannot see in the
  # literal text, discarding retrieval's opinion entirely loses the answer.
  # Fusion keeps both votes: rank 3 rather than 8.
  defp strategy, do: System.get_env("AI_RERANK_STRATEGY", "fused")

  # Swept 0 / 5 / 10 / 20 / 60 and it moves nothing: recall@5 and MRR are
  # identical at every value bar 0.01 of aggregate MRR at k=0. Five of 26 queries
  # shift by one rank, three one way and two the other — noise, not a gradient.
  #
  # Which is worth recording, because the score *spread* really does change (10x
  # at k=0, 1.15x at k=60) and it is tempting to assume the ordering follows. Over
  # ten items it mostly does not: at large k the ordering approximates rank-sum,
  # at k=0 it weights the head, and the two only disagree when an item is extreme
  # on one list and middling on the other.
  #
  # What mattered was the binary — whether retrieval's order votes at all, which
  # took recall@5 from 0.92 to 0.96 — not how heavily it votes.
  defp fusion_k, do: 60

  defp apply_strategy(docs, scored) do
    case strategy() do
      "gated" ->
        if scored |> Enum.map(&elem(&1, 0)) |> Enum.max() < 0,
          do: docs,
          else: sorted(scored)

      "fused" ->
        reranked = sorted(scored)

        order =
          StdioMcp.Docs.Fusion.rrf(
            [Enum.map(docs, & &1.id), Enum.map(reranked, & &1.id)],
            length(docs),
            fusion_k()
          )

        by_id = Map.new(docs, &{&1.id, &1})
        Enum.map(order, &by_id[&1])

      _pure ->
        sorted(scored)
    end
  end

  defp sorted(scored), do: scored |> Enum.sort_by(&(-elem(&1, 0))) |> Enum.map(&elem(&1, 1))

  defp score_and_sort(query, docs) do
    pairs = Enum.map(docs, &{query, text(&1)})

    case Nx.Serving.batched_run(@serving, pairs) do
      results ->
        case scores(results, length(pairs)) do
          {:ok, scores} ->
            apply_strategy(docs, Enum.zip(scores, docs))

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
  # `function` is already module-qualified on modern ExDoc, so joining it to
  # `module` produced "Boruta.Oauth.Client.Boruta.Oauth.Client.public?/1" — the
  # module name twice, spending tokens at the compiled sequence length on nothing.
  defp text(doc) do
    header =
      case {to_string(doc.module), to_string(doc.function)} do
        {_module, ""} ->
          to_string(doc.module)

        {module, function} ->
          if String.starts_with?(function, module), do: function, else: module <> "." <> function
      end

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

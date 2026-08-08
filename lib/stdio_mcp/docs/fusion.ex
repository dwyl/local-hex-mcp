defmodule StdioMcp.Docs.Fusion do
  @moduledoc """
  Reciprocal rank fusion over the keyword and vector candidate lists.

  Each arm contributes `1 / (k + rank)` for every document it returned, and an id
  absent from an arm contributes nothing. That is what makes this a **union**:
  the previous hybrid intersected the arms (`d.id in subquery(fts_ids)` ordered by
  cosine), so a document the vector arm ranked first but the keyword arm never
  matched could not be returned at all.

  ## Why the arms must stay shallow

  RRF scores agreement, and agreement is cheap at depth. An item ranked ~15 by
  both arms contributes `1/75 + 1/75 = 0.0267` and outranks one placed 3rd by a
  single arm at `1/63 = 0.0159`. With 40-deep arms there are enough
  mediocre-but-agreed documents to push a strong single-arm hit out of the fused
  top 10 — measured as recall@5 dropping from 1.00 to 0.96 purely by retrieving
  *more*. `Docs.Search` therefore takes 15 per arm, not 40.

  ## What this is for

  Not ranking. On this corpus RRF ranks slightly worse than the intersection it
  replaces (MRR 0.77 against 0.78) while scoring identical recall — its value is
  entirely that its candidate recall at depth 10 is 1.00 where the intersection's
  is 0.92. It exists to guarantee the answer reaches a pool small enough for the
  cross-encoder to sort well, and it is only worth having with that stage after
  it.
  """

  # 60 is the constant from the original RRF paper, where the job is fusing large
  # candidate sets produced by independent systems. That is exactly this fusion's
  # job — the two retrieval arms — and nothing reorders the result afterwards, so
  # the order this produces is the order the caller reads.
  #
  # `k` is a dial, not a constant, and every caller currently leaves it alone. It
  # earned the parameter when a second caller fused two permutations of the *same*
  # ten items (a cross-encoder's ordering against retrieval's, since removed — see
  # `Notes.md`). Over ten items it controls how far apart the scores spread:
  #
  #     k      best/worst score ratio over 10 items
  #     0      10.00x   first input dominates
  #     10      1.82x
  #     60      1.15x   near pure rank-averaging
  #
  # At 60 every score sits within 15% of every other, so fusing two orderings of
  # one set barely nudges it. Kept because the analysis is the hard part to
  # recover, and a future second ranker would need the same dial.
  @default_k 60

  @doc """
  Fuses ranked id lists into a single ranked list, best-first, capped at `limit`.

  `k` damps the influence of rank differences — larger flattens, smaller
  sharpens. Ranks are 1-based, so `k: 0` is well defined.
  """
  @spec rrf([[term()]], pos_integer(), non_neg_integer()) :: [term()]
  def rrf(ranked_lists, limit, k \\ @default_k) do
    ranked_lists
    |> Enum.flat_map(fn ids ->
      ids |> Enum.with_index(1) |> Enum.map(fn {id, rank} -> {id, 1 / (k + rank)} end)
    end)
    |> Enum.reduce(%{}, fn {id, score}, acc -> Map.update(acc, id, score, &(&1 + score)) end)
    |> Enum.sort_by(fn {_id, score} -> -score end)
    |> Enum.take(limit)
    |> Enum.map(fn {id, _score} -> id end)
  end
end

# Curator harness — exercises every action the knowledge-base curator can take.
#
#   mix run scripts/curator_harness.exs               # resets the knowledge table first
#   mix run scripts/curator_harness.exs --no-reset    # run against existing state
#   mix run scripts/curator_harness.exs --pause 2000  # ms between cases (default 1500)
#
# Each case costs several API calls (embed, curator, re-embed), so a full run
# fires roughly fifteen in quick succession and reliably trips Mistral's rate
# limit on the last case or two. The pause spaces them out; a 429 is also
# retried once, since losing the final case wastes the whole run.
#
# Cases run in order and depend on each other's state: `discard` needs its
# target already stored, `replace` needs something to correct. Each submission
# is made synchronously and its outcome read back from `knowledge_decisions`,
# which is the same record the MCP tool exposes via `request_id`.
#
# On `append` vs `merge`: the curator distinguishes "adds detail" from "both
# hold partial truths that belong together". That boundary is a judgement call
# with no crisp threshold, so both are accepted for either case and the summary
# reports which actually occurred rather than failing the run.

import Ecto.Query, only: [from: 2]
alias StdioMcp.Memory

{opts, _, _} = OptionParser.parse(System.argv(), strict: [reset: :boolean, pause: :integer])
reset? = Keyword.get(opts, :reset, true)
pause_ms = Keyword.get(opts, :pause, 1_500)

unless StdioMcp.AI.Client.memory_enabled?() do
  IO.puts(:stderr, "AI_API_KEY not set — curation is disabled, aborting.")
  System.halt(1)
end

if reset? do
  %{entries: n} = Memory.reset!()
  IO.puts(:stderr, "reset: removed #{n} entries\n")
end

# ── Fixtures ────────────────────────────────────────────────────────────────
# Two unrelated topics so that neighbours of one are below the 0.7 threshold of
# the other. Anything under 0.7 short-circuits to `create` without an LLM call.

vec_a = """
sqlite-vec cosine distance in Elixir: do not compute cosine distance over
embeddings in pure BEAM code with Enum.zip_reduce. It allocates heavily and
takes 50ms or more per query. Use SqliteVec.Ecto.Query.vec_distance_cosine/2
inside the Ecto query so the comparison runs natively in C inside SQLite,
in under 0.2ms with no BEAM allocation.
"""

caddy_b = """
Caddy reverse proxy buffers HTTP responses by default, which breaks
Server-Sent Events used by the MCP StreamableHTTP transport. The client opens a
connection but never receives tool capabilities. Add `flush_interval -1` to the
reverse_proxy directive so Caddy streams instead of buffering.
"""

cases = [
  %{
    label: "create — empty KB, no neighbours",
    expect: ["create"],
    text: vec_a
  },
  %{
    label: "create — unrelated topic, neighbours below 0.7",
    expect: ["create"],
    text: caddy_b
  },
  %{
    label: "discard — verbatim resubmission, no new facts",
    expect: ["discard"],
    text: vec_a
  },
  %{
    label: "append — same topic plus a new version note",
    expect: ["append", "merge"],
    text: """
    sqlite-vec cosine distance in Elixir: use
    SqliteVec.Ecto.Query.vec_distance_cosine/2 inside the Ecto query rather than
    computing distance in BEAM code. Additional note for sqlite_vec 0.2 and
    later: embeddings may be passed either as JSON strings via Jason.encode!/1
    or as binary float32 blobs via SqliteVec.float32/1. The blob form is roughly
    30% faster to decode on large result sets, and is required if the column is
    declared in a vec0 virtual table rather than as TEXT.
    """
  },
  %{
    # Sets up the merge case below by storing the second half of the story.
    # Adjacent to the first entry but a genuinely distinct question, so the
    # curator is expected to keep it separate rather than fold it in.
    label: "create — adjacent but distinct topic",
    expect: ["create"],
    text: """
    Choosing indexes for vector search in SQLite: sqlite-vec supports brute-force
    scans over a TEXT column as well as vec0 virtual tables. For collections
    below roughly 10k rows a brute-force scan with vec_distance_cosine is faster
    end to end than maintaining a vec0 table, because there is no index to keep
    in sync on write. Above that, the write cost is worth paying. This is the
    sizing question that sits alongside how the distance itself is computed.
    """
  },
  %{
    # Merge is the narrowest case to elicit: it needs two stored entries that
    # each hold an incomplete half, and text that says so. Anything less
    # specific reads as either "adds detail" (append) or "different subject"
    # (create).
    label: "merge — spans two entries holding partial truths",
    expect: ["merge", "append"],
    text: """
    Vector search in SQLite from Elixir, complete picture: the two existing notes
    each cover only half of this and belong together. Computing the distance and
    choosing the storage layout are the same decision, not two: vec_distance_cosine
    run natively in C is only fast when the collection is small enough to scan
    brute-force, and the moment you move to a vec0 virtual table for larger
    collections the cost model inverts, because the index maintenance on write is
    what dominates rather than the per-row distance computation. Neither the
    distance-computation note nor the index-sizing note is actionable without the
    other: you cannot pick a distance strategy without knowing the collection size,
    and you cannot size the collection without knowing the scan cost.
    """
  },
  %{
    label: "replace — states the stored fact is now wrong",
    expect: ["replace"],
    text: """
    CORRECTION to the Caddy SSE note: `flush_interval -1` alone is NOT sufficient
    and that advice is now wrong. As of Caddy 2.8 the directive was renamed and
    `flush_interval` is ignored inside a `reverse_proxy` block unless streaming
    is also enabled explicitly. The working configuration is to set
    `stream_close_delay 0` together with the flush interval. Configs relying on
    `flush_interval -1` by itself silently buffer again after upgrading.
    """
  },
  %{
    label: "deprecate — subject no longer exists at all",
    expect: ["deprecate", "replace"],
    text: """
    The Caddy reverse-proxy guidance is now entirely obsolete and should be
    retired. The MCP deployment no longer sits behind Caddy at all: the service
    was moved to a direct Bandit listener with TLS terminated by the platform,
    so there is no reverse_proxy directive of any kind in the deployment. No
    part of the previous Caddy buffering advice applies to any current setup.
    """
  }
]

# ── Run ─────────────────────────────────────────────────────────────────────

defmodule Harness do
  # Collapses the stored outcome back onto the six curator action names.
  def effective(%{action: "updated", strategy: s}) when s in ~w(append merge replace), do: s
  def effective(%{action: "created"}), do: "create"
  def effective(%{action: "created (fallback)"}), do: "create"
  def effective(%{action: "discarded"}), do: "discard"
  def effective(%{action: "deprecated"}), do: "deprecate"
  def effective(%{action: other}), do: other || "?"

  def pct(nil), do: "  -  "
  def pct(sim), do: :erlang.float_to_binary(sim * 100, decimals: 1) <> "%"

  # Truncates as well as pads, so a long label cannot run into the next column.
  def pad(s, n) do
    s = to_string(s)

    if String.length(s) > n - 1,
      do: String.slice(s, 0, n - 2) <> "… ",
      else: String.pad_trailing(s, n)
  end
end

rate_limited? = fn
  %{status: "failed", detail: detail} when is_binary(detail) -> detail =~ "429"
  _ -> false
end

submit = fn text, tag ->
  request_id = "harness-#{System.system_time(:millisecond)}-#{tag}"
  {:ok, _} = Memory.open_decision(request_id, text)
  Memory.process_remember(text, request_id)

  case Memory.get_decision(request_id) do
    {:ok, d} -> d
    {:error, _} -> nil
  end
end

results =
  cases
  |> Enum.with_index(1)
  |> Enum.map(fn {c, i} ->
    if i > 1, do: Process.sleep(pause_ms)

    decision =
      case submit.(c.text, i) do
        d when d != nil ->
          if rate_limited?.(d),
            do:
              (
                Process.sleep(20_000)
                submit.(c.text, "#{i}r")
              ),
            else: d

        nil ->
          nil
      end

    case decision do
      nil ->
        Map.merge(c, %{got: "NO RECORD", decision: nil, ok: false})

      d ->
        got = Harness.effective(d)
        Map.merge(c, %{got: got, decision: d, ok: got in c.expect})
    end
  end)

IO.puts(:stderr, "\n" <> String.duplicate("─", 96))

IO.puts(
  :stderr,
  Harness.pad("case", 46) <>
    Harness.pad("expected", 18) <> Harness.pad("got", 12) <> Harness.pad("sim", 8) <> "target"
)

IO.puts(:stderr, String.duplicate("─", 96))

for r <- results do
  mark = if r.ok, do: "✓", else: "✗"
  sim = if r.decision, do: Harness.pct(r.decision.top_similarity), else: "  -  "
  target = if r.decision && r.decision.target_id, do: "##{r.decision.target_id}", else: "-"

  IO.puts(
    :stderr,
    mark <>
      " " <>
      Harness.pad(r.label, 44) <>
      Harness.pad(Enum.join(r.expect, "|"), 18) <>
      Harness.pad(r.got, 12) <> Harness.pad(sim, 8) <> target
  )
end

IO.puts(:stderr, String.duplicate("─", 96))

all_actions = ~w(create discard append merge replace deprecate)
observed = results |> Enum.map(& &1.got) |> Enum.uniq()
missing = all_actions -- observed

IO.puts(:stderr, "observed: #{Enum.join(Enum.filter(all_actions, &(&1 in observed)), ", ")}")

if missing != [] do
  IO.puts(:stderr, "NOT exercised: #{Enum.join(missing, ", ")}")
end

entries = StdioMcp.Repo.aggregate(StdioMcp.Knowledge, :count)

outdated =
  StdioMcp.Repo.aggregate(from(k in StdioMcp.Knowledge, where: k.outdated == true), :count)

IO.puts(:stderr, "\nknowledge rows: #{entries} (#{outdated} marked outdated)")

for k <- StdioMcp.Repo.all(StdioMcp.Knowledge) do
  flag = if k.outdated, do: " [OUTDATED]", else: ""
  stack = k.metadata["stack"] || []
  IO.puts(:stderr, "  ##{k.id} #{k.kind}#{flag} — #{String.slice(k.title, 0, 60)}")
  IO.puts(:stderr, "      stack=#{inspect(stack)} domain=#{inspect(k.metadata["domain"])}")
end

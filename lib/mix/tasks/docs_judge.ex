defmodule Mix.Tasks.Docs.Judge do
  @shortdoc "Generates the relevance-judgement file from what the server actually returns."

  @moduledoc """
  Runs every eval query through the **production** search path and writes what it
  returned to `priv/eval/judgements.md` for a human to mark.

  Deliberately calls `StdioMcp.Docs.Search.search/2` rather than reimplementing
  the arms: a judgement should describe what the server answers, not what a
  harness approximates.

  Existing marks are preserved on regeneration — they key on package + URL, which
  survives re-chunking — so only genuinely new documents come back as `?`.

  ## Usage

      mix docs.judge              # top 8 per query
      mix docs.judge --depth 5
  """

  use Mix.Task

  alias StdioMcp.AI.Client
  alias StdioMcp.Docs.Judgements

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [depth: :integer])
    depth = Keyword.get(opts, :depth, 8)

    Mix.Task.run("app.start")

    existing = Judgements.load()

    entries =
      Mix.Tasks.Docs.Eval.queries()
      |> Enum.map(fn q ->
        Mix.shell().info("  #{q.package}: #{q.query}")
        {q.query, q.kind, results(q, depth)}
      end)

    File.mkdir_p!(Path.dirname(Judgements.path()))
    File.write!(Judgements.path(), Judgements.render(entries, existing))

    {judged, total} = coverage(entries, existing)

    Mix.shell().info("""

    Wrote #{Judgements.path()}
      #{total} results across #{length(entries)} queries
      #{judged} already judged, #{total - judged} awaiting a mark

    Mark `y` / `n`, then: mix docs.eval --judged
    """)
  end

  defp results(q, depth) do
    embedding =
      case Client.embed(q.query) do
        {:ok, vector} -> Jason.encode!(vector)
        {:error, reason} -> Mix.raise("embedding failed: #{inspect(reason)}")
      end

    {rows, _notices} =
      StdioMcp.Docs.Search.search(q.query,
        package: q.package,
        version: Map.get(q, :version),
        embedding: embedding,
        limit: depth
      )

    Enum.map(rows, fn r ->
      %{package: r.package, url: r.hexdocs_url, signature: r.signature, content: r.content}
    end)
  end

  defp coverage(entries, existing) do
    Enum.reduce(entries, {0, 0}, fn {query, _kind, results}, {judged, total} ->
      marked =
        Enum.count(results, fn r ->
          Judgements.verdict(existing, query, r.package, r.url) != :unjudged
        end)

      {judged + marked, total + length(results)}
    end)
  end
end

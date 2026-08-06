defmodule StdioMcp.Docs.QuerySanitizer do
  @moduledoc """
  Turns a natural-language query into an FTS5 `MATCH` expression.

  The FTS5 query grammar is small and unforgiving: `Req.merge/2` unquoted is a
  syntax error, not a search for `Req.merge/2`. So every term is emitted as a
  quoted phrase, which is always legal and, for a single-token term, means
  exactly what the bareword would have meant.

  ## Why the tokenizer and this module have to be designed together

  Identifiers are the queries FTS is *supposed* to be good at, and default
  `unicode61` splits them apart: `Boruta.Oauth.token/2` becomes
  `boruta OR oauth OR token OR 2`, four common words in a 544-row package, which
  is how the exact-match query for a function ranked **22nd** in its own package.

  Adding `_` and `/` to `tokenchars` keeps `token/2` and `chunk_overlap` whole,
  and those are discriminative. Adding `.` and `:` as well is tempting and wrong:
  they end sentences. With `.` as a token character, `…uses Req.merge/2.` indexes
  as `req.merge/2.` — trailing period included — and no query ever written
  matches it. Punctuation that terminates prose cannot be part of a token.

  ## Expansion rather than replacement

  A term holding a token character is emitted **both** whole and split:

      "chunk_overlap"  ->  "chunk_overlap" OR "chunk" OR "overlap"

  Keeping only the whole form would lose the prose query — a guide that says
  "chunk overlap" in a sentence no longer matches the joined token. Keeping only
  the split form is the current behaviour, which is what buried `token/2`. Both
  costs one extra OR clause and lets BM25 do the work: a document matching the
  precise form matches strictly more clauses than one matching only the words.

  Bare arities are dropped from the expansion (`token/2` yields `token`, not
  `token` and `2`) since `2` on its own matches most of any package.
  """

  # Mirrors the `tokenchars` of the `package_docs_fts` table. The two definitions
  # are separate files and must agree: a character the tokenizer glues into a
  # token but the sanitiser strips produces a query that cannot match the index it
  # is querying.
  @token_chars ["_", "/"]

  @doc """
  Builds the `MATCH` expression, or `""` when the query holds nothing searchable.

  `""` is the caller's signal to skip FTS entirely rather than to run an empty
  match, which FTS5 rejects.
  """
  @spec to_match(String.t()) :: String.t()
  def to_match(query) when is_binary(query) do
    query
    |> terms()
    |> Enum.flat_map(&expand/1)
    |> Enum.uniq()
    |> Enum.map_join(" OR ", &quote_term/1)
  end

  # Anything that is not a letter, a digit, whitespace or a token character
  # becomes a separator — which is exactly what the tokenizer does to the
  # documents, so query and index agree on where terms begin and end.
  defp terms(query) do
    query
    |> String.replace(~r/[^\p{L}\p{N}\s#{Enum.join(@token_chars)}]/u, " ")
    |> String.split()
    |> Enum.map(&String.trim(&1, "/"))
    |> Enum.reject(&(&1 == ""))
  end

  defp expand(term) do
    case split_term(term) do
      [_single] -> [term]
      parts -> [term | Enum.reject(parts, &arity?/1)]
    end
  end

  defp split_term(term), do: String.split(term, @token_chars, trim: true)

  defp arity?(part), do: String.match?(part, ~r/^\d+$/)

  # FTS5 escapes a double quote inside a string by doubling it.
  defp quote_term(term), do: ~s("#{String.replace(term, ~s("), ~s(""))}")
end

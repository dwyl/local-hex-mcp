defmodule StdioMcp.Docs.EmbeddingConfig do
  @moduledoc """
  What built the vector index, and whether it agrees with what is querying it.

  Embeddings are only comparable to other embeddings from the same model. Mixing
  two models produces one of two failures, and the worse one is the quiet one:

    * **Different dimensions** — sqlite-vec raises, `Docs.Search.run_query/4`
      rescues, and the search silently degrades to FTS-only. Observed:
      `anubis_mcp` at 1536 dims against 1024-dim queries, for days, looking
      merely badly ranked.
    * **Same dimensions, different model** — nothing raises at all. Cosine
      distance between two unrelated vector spaces is noise, and the results are
      simply wrong with no signal anywhere.

  So the check compares the **model name**, not the dimension: two 1024-dim
  models are just as incompatible as two of different size, and the name is free
  to compare while the dimension costs an API call to learn.

  `dims` is still recorded, because it is what a `vec0` virtual table needs in
  its DDL if the storage ever moves there, and because it is the number that
  makes a mismatch legible in a diagnostic.
  """

  use Ecto.Schema

  import Ecto.Query

  alias StdioMcp.AI.Client
  alias StdioMcp.Repo

  require Logger

  @row_id 1

  @primary_key {:id, :integer, autogenerate: false}
  schema "embedding_config" do
    field(:model, :string)
    field(:dims, :integer)

    timestamps()
  end

  @typedoc """
  `:unset` is an index built before this table existed. It is not an error and
  must not block a search — there is no way to know what produced those vectors,
  so the only honest thing is to proceed and say the index is unverified.
  """
  @type status :: :ok | :unset | {:mismatch, String.t(), String.t()}

  @doc "The recorded configuration, or `nil` for an index that predates it."
  @spec get() :: %__MODULE__{} | nil
  def get, do: Repo.one(from(c in __MODULE__, where: c.id == @row_id))

  @doc """
  Compares the recorded model against the one currently configured.

  Pure DB read plus an application-env lookup — no network — so it is cheap
  enough to run on every search.
  """
  @spec check() :: status()
  def check, do: check(get(), Client.embed_model())

  @spec check(%__MODULE__{} | nil, String.t()) :: status()
  def check(nil, _current), do: :unset
  def check(%__MODULE__{model: model}, model), do: :ok
  def check(%__MODULE__{model: stored}, current), do: {:mismatch, stored, current}

  @doc """
  Records the model and dimension an ingestion just used.

  Called after embedding succeeds and before rows are written, so a refused
  ingest leaves the previous record intact.
  """
  @spec record(String.t(), pos_integer()) :: :ok | {:error, term()}
  def record(model, dims) when is_binary(model) and is_integer(dims) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    %__MODULE__{}
    |> Ecto.Changeset.change(%{
      id: @row_id,
      model: model,
      dims: dims,
      inserted_at: now,
      updated_at: now
    })
    |> Repo.insert(
      on_conflict: [set: [model: model, dims: dims, updated_at: now]],
      conflict_target: :id
    )
    |> case do
      {:ok, _config} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Forgets the recorded configuration.

  Only `mix docs.reindex` should call this: clearing the record is what allows
  the next ingestion to adopt a different model, and it is only safe when every
  package is about to be re-embedded.
  """
  @spec clear() :: :ok
  def clear do
    Repo.delete_all(from(c in __MODULE__))
    Logger.info("[EmbeddingConfig] cleared — next ingestion sets the model")
    :ok
  end

  @doc """
  Guards an ingestion against writing vectors from a second model.

  Returning an error here is deliberate: a mixed index cannot be repaired by
  searching harder, and the previous rows are more useful than a half-converted
  set. `mix docs.reindex` is the supported way to change models.
  """
  @spec allow_ingest(String.t()) ::
          :ok | {:error, {:embedding_model_mismatch, String.t(), String.t()}}
  def allow_ingest(current) do
    case check(get(), current) do
      :ok -> :ok
      :unset -> :ok
      {:mismatch, stored, current} -> {:error, {:embedding_model_mismatch, stored, current}}
    end
  end

  @doc """
  Human-readable explanation of a mismatch, for the `notices` a tool returns.

  It has to name the fix, because there is no way for the caller to work it out:
  re-running the search cannot help, and `refresh: true` on one package would
  only move the mixture around.
  """
  @spec mismatch_notice(String.t(), String.t()) :: String.t()
  def mismatch_notice(stored, current) do
    "The docs index was built with the embedding model '#{stored}', but this " <>
      "server is configured to use '#{current}'. Vectors from two models are not " <>
      "comparable, so semantic ranking is disabled and these results come from " <>
      "keyword search alone. Either set AI_EMBED_MODEL back to '#{stored}', or " <>
      "re-embed everything with `mix docs.reindex`."
  end
end

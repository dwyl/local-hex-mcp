defmodule StdioMcp.Tools.Recall do
  @moduledoc """
  Search this project's local knowledge base for past pain points, architectural
  decisions and bug fixes previously saved with `remember`.

  Call it **before** attempting a fix, not after — its value is avoiding a repeat
  of an investigation someone already finished:

    * on any command or test failure, search the error message with
      `kind: "pain_point"`;
    * on a second iteration — if the first edit did not fix the error, search the
      specific function or module before editing again;
    * before changing infrastructure config (`runtime.exs`, `docker-compose.yml`,
      Caddyfile, OAuth settings), where past attempts are often already recorded.

  Optional filters: `kind` (`pain_point`, `pattern`, `decision`, `package_note`)
  and `package`. This searches locally recorded experience, not package
  documentation — for docs use `search_docs`.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias StdioMcp.Knowledge.Vocabulary
  alias StdioMcp.Memory

  schema do
    field(:query, :string,
      required: true,
      description:
        "Search query for past architectural decisions, solved issues, or lessons learned."
    )

    # Derived from the vocabulary: this schema previously advertised filter
    # values the writer never emitted, so every filtered search returned nothing.
    field(:kind, :string, description: Vocabulary.kinds_for_schema())

    field(:package, :string,
      description: "Filter by library or package name (e.g. 'anubis_mcp', 'boruta', 'req')."
    )
  end

  @impl true
  def execute(params, frame) do
    query = params[:query]
    opts = [limit: 5, kind: params[:kind], package: params[:package]]

    results = Memory.search(query, opts)

    formatted =
      Enum.map(results, fn r ->
        %{
          id: r.id,
          title: r.title,
          kind: r.kind,
          content: r.content,
          metadata: r.metadata
        }
      end)

    {:reply, Response.text(Response.tool(), Jason.encode!(formatted)), frame}
  rescue
    e ->
      require Logger

      Logger.error(
        "[Recall] Tool execution failed:\n#{Exception.format(:error, e, __STACKTRACE__)}"
      )

      {:reply, Response.text(Response.tool(), "Recall failed: #{Exception.message(e)}"), frame}
  end
end

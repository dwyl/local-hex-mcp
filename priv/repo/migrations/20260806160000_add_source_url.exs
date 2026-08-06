defmodule StdioMcp.Repo.Migrations.AddSourceUrl do
  use Ecto.Migration

  @moduledoc """
  Stores the per-function "View Source" link ExDoc already generates.

  It is in the tarball we download anyway, points at an exact file and line, and
  for packages that tag their docs it is pinned to the version — phoenix emits
  `blob/v1.8.9/lib/phoenix/router.ex#L1428`. The HTML walk was discarding it:
  `icon-action` elements are stripped as chrome, which is right for the anchor
  *text* ("View Source" is noise) and wrong for the `href`.

  Nullable because coverage is uneven — a package that does not configure
  `source_url` in its docs config emits none at all (anubis_mcp: zero).
  """

  def change do
    alter table(:package_docs) do
      add(:source_url, :string)
    end
  end
end

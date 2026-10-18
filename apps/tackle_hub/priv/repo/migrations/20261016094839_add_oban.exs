defmodule Tackle.Hub.Repo.Migrations.AddOban do
  use Ecto.Migration

  # Pinned, so a later Oban upgrade adds its own migration instead of
  # changing what this one does.
  def up, do: Oban.Migration.up(version: 14)

  def down, do: Oban.Migration.down(version: 1)
end

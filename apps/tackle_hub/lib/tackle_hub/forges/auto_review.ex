defmodule Tackle.Hub.Forges.AutoReview do
  @moduledoc """
  When a repository's pull requests are reviewed without a command
  (docs/TACKLE_HUB_PLAN.md §7.7): `:off`, `:on_open` (opened, reopened, and
  ready for review), or `:on_open_and_push` (also every new head).
  """

  use Ash.Type.Enum, values: [:off, :on_open, :on_open_and_push]
end

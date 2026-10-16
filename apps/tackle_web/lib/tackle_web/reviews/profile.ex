defmodule Tackle.Web.Reviews.Profile do
  @moduledoc """
  How many findings a review reports: the `Tackle.Review.Rank` profiles
  (`:quiet`, `:default`, and `:assertive`).
  """

  alias Tackle.Review.Rank

  use Ash.Type.Enum, values: Rank.profiles()
end

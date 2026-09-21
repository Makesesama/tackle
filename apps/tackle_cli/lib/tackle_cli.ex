defmodule Tackle.CLI do
  @moduledoc """
  Command-line frontend for the Tackle developer harness.

  The CLI owns argument parsing and terminal presentation. It delegates runtime
  composition, adapter loading, sessions, and turns to the root `Tackle`
  harness.
  """

  alias Tackle.CLI.Main

  @doc "Entrypoint used by escripts and tests."
  @spec main([String.t()]) :: non_neg_integer()
  defdelegate main(argv \\ []), to: Main
end

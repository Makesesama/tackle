defmodule Tackle.Elixir.Diagnostic do
  @moduledoc """
  A compiler diagnostic from a project node: a `Mix.Task.Compiler.Diagnostic`
  reduced to plain, checked data.

  `file` is an absolute path as seen by the executor, or `nil` when the
  compiler gave no file; `line` and `column` are `nil` when unknown.
  """

  @enforce_keys [:severity, :message]
  defstruct [:severity, :file, :line, :column, :message, :compiler]

  @type severity :: :error | :warning | :information | :hint

  @type t :: %__MODULE__{
          severity: severity(),
          file: Path.t() | nil,
          line: non_neg_integer() | nil,
          column: non_neg_integer() | nil,
          message: String.t(),
          compiler: String.t() | nil
        }
end

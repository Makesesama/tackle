defmodule GixEx.Diff.Hunk do
  @moduledoc """
  A hunk of a `GixEx.Diff.File`, as `git diff` would print it.

  `header` is the full `@@ -a,b +c,d @@ section` line. The ranges follow Git:
  a side without lines starts at the line before the hunk, so a new file is
  `-0,0`. `section` is the heading Git prints after the ranges, found with
  Git's default rule: the nearest line above the hunk in the old file that
  starts with a letter, `_`, or `$`, cut to 80 bytes. Language-specific rules
  configured with `diff=<driver>` attributes are not applied.

  Every line carries its absolute line numbers: removed lines have only an
  `old` number, added lines only a `new` number, and context lines both.
  `text` excludes the line break; `no_newline` is true for the last line of a
  file version that does not end in one.
  """

  @enforce_keys [:header, :old_start, :old_count, :new_start, :new_count, :section, :lines]
  defstruct [:header, :old_start, :old_count, :new_start, :new_count, :section, :lines]

  @typedoc "The kind of a diff line."
  @type kind :: :add | :remove | :context

  @typedoc "One line of a hunk."
  @type line :: %{
          kind: kind(),
          old: pos_integer() | nil,
          new: pos_integer() | nil,
          text: binary(),
          no_newline: boolean()
        }

  @type t :: %__MODULE__{
          header: binary(),
          old_start: non_neg_integer(),
          old_count: non_neg_integer(),
          new_start: non_neg_integer(),
          new_count: non_neg_integer(),
          section: binary(),
          lines: [line()]
        }
end

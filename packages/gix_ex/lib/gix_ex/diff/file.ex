defmodule GixEx.Diff.File do
  @moduledoc """
  One file of a diff returned by `GixEx.diff/4`.

  `path` is the new path, or the old path of a deleted file. `old_path` is
  `nil` for an added file, the source of a renamed or copied one, and equal to
  `path` otherwise. Paths are relative to the repository root.

  An `:unmerged` file is a path with a merge conflict in the index; like
  `git diff --cached`, it has no modes, hunks, or contents.

  `old_mode` and `new_mode` are Git file modes such as `0o100644`, or `nil` on
  the side the file does not exist on. A file that changes between regular
  file, symbolic link, and submodule is reported as a deletion followed by an
  addition, as Git does.

  `binary` is true when either side holds a NUL byte in its first 8000 bytes or
  is larger than the `:max_file_bytes` option, or when `.gitattributes` in the
  index marks the path `-diff` or `binary` (or sets a `diff=<driver>` whose
  `diff.<driver>.binary` is true). A path with the `diff` attribute set is
  always text. A binary file has no hunks and counts no additions or
  deletions. A pure rename or a mode change has no hunks
  either.

  `old_content` and `new_content` are the full text of each side when the
  `:contents` option is set, and `nil` otherwise, for a side that does not
  exist, and for binary files.
  """

  alias GixEx.Diff.Hunk

  @enforce_keys [:path, :old_path, :status, :old_mode, :new_mode, :binary, :hunks]
  defstruct [
    :path,
    :old_path,
    :status,
    :old_mode,
    :new_mode,
    :binary,
    :old_content,
    :new_content,
    additions: 0,
    deletions: 0,
    hunks: []
  ]

  @typedoc "How a file changed."
  @type status :: :added | :deleted | :modified | :renamed | :copied | :unmerged

  @type t :: %__MODULE__{
          path: binary(),
          old_path: binary() | nil,
          status: status(),
          old_mode: non_neg_integer() | nil,
          new_mode: non_neg_integer() | nil,
          binary: boolean(),
          additions: non_neg_integer(),
          deletions: non_neg_integer(),
          hunks: [Hunk.t()],
          old_content: binary() | nil,
          new_content: binary() | nil
        }
end

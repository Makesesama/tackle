defmodule GixEx.Repository do
  @moduledoc """
  An open repository, as returned by `GixEx.open/1`.

  `workdir` is the root of the working tree (what `git rev-parse
  --show-toplevel` prints), or `nil` for a bare repository. `git_dir` is the
  repository's `.git` directory. Both are absolute, with symbolic links
  resolved.

  The handle may be shared between processes; each call works on its own view
  of the repository, so changes to files, refs, and objects on disk are seen by
  the next call. The repository's configuration is read once, when it is
  opened.
  """

  @enforce_keys [:ref, :workdir, :git_dir]
  defstruct [:ref, :workdir, :git_dir]

  @type t :: %__MODULE__{
          ref: reference(),
          workdir: Path.t() | nil,
          git_dir: Path.t()
        }

  defimpl Inspect do
    def inspect(%{workdir: workdir, git_dir: git_dir}, _opts) do
      "#GixEx.Repository<#{workdir || git_dir}>"
    end
  end
end

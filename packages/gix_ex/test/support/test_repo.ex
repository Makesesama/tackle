defmodule GixEx.TestRepo do
  @moduledoc false
  # Builds throwaway repositories with the `git` executable, and runs `git` on
  # them to compare GixEx with the reference implementation.

  import ExUnit.Assertions

  @env [
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_AUTHOR_NAME", "Test"},
    {"GIT_AUTHOR_EMAIL", "test@example.com"},
    {"GIT_COMMITTER_NAME", "Test"},
    {"GIT_COMMITTER_EMAIL", "test@example.com"},
    {"LC_ALL", "C"}
  ]

  @doc "Creates an empty repository on `main` in a fresh temporary directory."
  def init!(context) do
    dir = Path.join(System.tmp_dir!(), "gix_ex-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(context, fn -> File.rm_rf!(dir) end)
    git!(dir, ["init", "--quiet", "--initial-branch=main"])
    dir
  end

  def git_env, do: @env

  def git!(dir, args) do
    {output, status} = System.cmd("git", args, cd: dir, env: @env, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed (#{status}):\n#{output}"
    output
  end

  def write!(dir, path, content) do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  @doc "Stages everything and commits; returns the new commit id."
  def commit!(dir, message) do
    git!(dir, ["add", "--all"])
    git!(dir, ["commit", "--quiet", "--allow-empty", "--message", message])
    dir |> git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  # GixEx's default algorithm is histogram, which matches Git's exactly.
  @diff_args [
    "--no-color",
    "--no-ext-diff",
    "--no-textconv",
    "--no-relative",
    "--histogram"
  ]

  @doc """
  Git's view of a diff in the shape `render/1` produces: one entry per file
  with its status, paths, counts, and hunk text. Options: `:context`
  (default 3) and `:renames` (default true).
  """
  def git_diff(dir, revisions, opts \\ []) do
    context = Keyword.get(opts, :context, 3)
    renames = if Keyword.get(opts, :renames, true), do: "--find-renames", else: "--no-renames"
    args = @diff_args ++ [renames | revisions] ++ ["--"]

    statuses = dir |> git!(["diff", "--name-status" | args]) |> lines()
    counts = dir |> git!(["diff", "--numstat" | args]) |> lines()
    # `--unified` implies `--patch`, so it is only passed here.
    hunks = dir |> git!(["diff", "--unified=#{context}" | args]) |> hunk_text()

    assert length(statuses) == length(counts) and length(counts) == length(hunks),
           inspect({statuses, counts, hunks})

    [statuses, counts, hunks]
    |> Enum.zip()
    |> Enum.map(fn {status, count, hunk} ->
      {kind, paths} = status(status)
      [additions, deletions | _] = String.split(count, "\t")

      %{
        status: kind,
        paths: paths,
        counts: {additions, deletions},
        hunks: hunk
      }
    end)
  end

  @doc "Renders GixEx files in the shape of `git_diff/3`."
  def render(files) do
    Enum.map(files, fn file ->
      %{
        status: file.status,
        paths: paths(file),
        counts: counts(file),
        hunks: Enum.map_join(file.hunks, &render_hunk/1)
      }
    end)
  end

  defp paths(%{status: status, old_path: old, path: new}) when status in [:renamed, :copied],
    do: [old, new]

  defp paths(%{path: path}), do: [path]

  defp counts(%{binary: true}), do: {"-", "-"}
  defp counts(file), do: {to_string(file.additions), to_string(file.deletions)}

  defp render_hunk(hunk) do
    lines =
      Enum.map(hunk.lines, fn line ->
        marker =
          case line.kind do
            :add -> "+"
            :remove -> "-"
            :context -> " "
          end

        note = if line.no_newline, do: "\\ No newline at end of file\n", else: ""
        marker <> line.text <> "\n" <> note
      end)

    IO.iodata_to_binary([hunk.header, "\n" | lines])
  end

  defp status(line) do
    case String.split(line, "\t") do
      ["A", path] -> {:added, [path]}
      ["D", path] -> {:deleted, [path]}
      ["M", path] -> {:modified, [path]}
      ["T", path] -> {:type_changed, [path]}
      ["R" <> _, old, new] -> {:renamed, [old, new]}
      ["C" <> _, old, new] -> {:copied, [old, new]}
    end
  end

  # The hunk text of each file of a patch, in order, without the file headers.
  defp hunk_text(patch) do
    patch
    |> String.split(~r/^diff --git /m, trim: true)
    |> Enum.map(fn file ->
      case String.split(file, ~r/^(?=@@ )/m, parts: 2) do
        [_headers, hunks] -> hunks
        [_headers] -> ""
      end
    end)
  end

  defp lines(output), do: String.split(output, "\n", trim: true)
end

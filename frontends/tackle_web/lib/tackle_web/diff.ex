defmodule Tackle.Web.Diff do
  @moduledoc """
  Builds the structure the review UI renders out of a git patch.

  The patch is parsed into files, hunks and lines, and each line is paired with a
  highlighted fragment of the file version it belongs to: added and context lines
  come from the head side, removed lines from the base side. Reading the whole
  blob (rather than the hunk) is what keeps multi-line lexer state intact.
  """

  alias GitDiff.Line
  alias Tackle.Web.{Git, Highlight}

  @type kind :: :add | :remove | :context | :note

  @type line :: %{
          kind: kind,
          old: pos_integer() | nil,
          new: pos_integer() | nil,
          html: String.t() | nil,
          text: String.t() | nil
        }

  @type file :: %{
          path: Path.t(),
          old_path: Path.t() | nil,
          new_path: Path.t() | nil,
          status: :added | :deleted | :modified | :renamed,
          additions: non_neg_integer(),
          deletions: non_neg_integer(),
          hunks: [%{header: String.t(), lines: [line]}]
        }

  @type diff :: %{
          base_sha: String.t(),
          head_sha: String.t(),
          files: [file],
          additions: non_neg_integer(),
          deletions: non_neg_integer()
        }

  @doc """
  Loads and renders the diff that `head` introduces relative to `base`.
  """
  @spec load(Path.t(), String.t(), String.t()) :: {:ok, diff} | {:error, String.t()}
  def load(repo, base, head) do
    with {:ok, %{base_sha: base_sha, head_sha: head_sha, patch: patch}} <-
           Git.load(repo, base, head),
         {:ok, patches} <- parse(patch) do
      files = Enum.map(patches, &build_file(&1, repo, base_sha, head_sha))

      {:ok,
       %{
         base_sha: base_sha,
         head_sha: head_sha,
         files: files,
         additions: files |> Enum.map(& &1.additions) |> Enum.sum(),
         deletions: files |> Enum.map(& &1.deletions) |> Enum.sum()
       }}
    end
  end

  defp parse(patch) do
    case GitDiff.parse_patch(patch) do
      {:ok, patches} -> {:ok, patches}
      {:error, _reason} -> {:error, "the diff could not be parsed"}
    end
  end

  defp build_file(patch, repo, base_sha, head_sha) do
    old_path = patch.headers["file_a"]
    new_path = patch.headers["file_b"]

    # Both sides are highlighted so a removed line keeps its colour: taking the
    # fragments from the side the line exists on is the whole point.
    old_lines = highlight(repo, base_sha, old_path)
    new_lines = highlight(repo, head_sha, new_path)

    %{
      path: new_path || old_path,
      old_path: old_path,
      new_path: new_path,
      status: status(patch),
      additions: count(patch, :add),
      deletions: count(patch, :remove),
      hunks: Enum.map(patch.chunks, &build_hunk(&1, old_lines, new_lines))
    }
  end

  @doc """
  The review anchor a rendered line maps to, or `nil` for rows that carry none.

  Comments are stored against a side and a line number rather than a diff
  offset, so this is what ties a rendered row back to the comment attached to
  it. Context lines exist on both sides and anchor to the new one; the
  no-newline marker belongs to neither.
  """
  @spec anchor(map()) :: {:new | :old, pos_integer()} | nil
  def anchor(%{kind: :add, new: new}) when is_integer(new), do: {:new, new}
  def anchor(%{kind: :remove, old: old}) when is_integer(old), do: {:old, old}
  def anchor(%{kind: :context, new: new}) when is_integer(new), do: {:new, new}
  def anchor(%{kind: :context, old: old}) when is_integer(old), do: {:old, old}
  def anchor(_line), do: nil

  # An added file has no blob on the base side and a deleted one has none on the
  # head side. Anything unreadable or binary simply yields no fragments, and the
  # renderer falls back to escaped plain text.
  defp highlight(_repo, _ref, nil), do: %{}

  defp highlight(repo, ref, path) do
    with {:ok, content} <- Git.blob(repo, ref, path),
         true <- text?(content) do
      Highlight.lines(content, path)
    else
      _error -> %{}
    end
  rescue
    # An extension Lumis has no grammar for, a parser that is not loaded, or
    # source it rejects must not take the whole review down: the renderer falls
    # back to escaped plain text for every line of that file.
    _error -> %{}
  end

  defp text?(content) do
    String.valid?(content) and not String.contains?(content, <<0>>)
  end

  # GitDiff reports /dev/null as a missing side rather than a path.
  defp status(%{from: nil}), do: :added
  defp status(%{to: nil}), do: :deleted
  defp status(%{from: from, to: to}) when from != to, do: :renamed
  defp status(_patch), do: :modified

  defp count(patch, type) do
    patch.chunks
    |> Enum.flat_map(& &1.lines)
    |> Enum.count(&(&1.type == type))
  end

  defp build_hunk(chunk, old_lines, new_lines) do
    %{
      header: chunk.header,
      lines: Enum.map(chunk.lines, &build_line(&1, old_lines, new_lines))
    }
  end

  # "\ No newline at end of file" is reported as a context line carrying no line
  # numbers on either side: it annotates the preceding line rather than being
  # one, so it must not be looked up in the highlighted fragment maps.
  defp build_line(%Line{text: "\\" <> note}, _old_lines, _new_lines) do
    %{kind: :note, old: nil, new: nil, html: nil, text: String.trim_leading(note)}
  end

  defp build_line(%Line{type: :add} = line, _old_lines, new_lines) do
    number = to_integer(line.to_line_number)
    render(:add, nil, number, fragment(new_lines, number, line.text))
  end

  defp build_line(%Line{type: :remove} = line, old_lines, _new_lines) do
    number = to_integer(line.from_line_number)
    render(:remove, number, nil, fragment(old_lines, number, line.text))
  end

  defp build_line(%Line{type: :context} = line, old_lines, new_lines) do
    old_number = to_integer(line.from_line_number)
    new_number = to_integer(line.to_line_number)

    # A context line exists on both sides. The head side is preferred because
    # that is the version the change produces; the base side is the fallback for
    # a line only the base still has.
    html =
      lookup(new_lines, new_number) ||
        lookup(old_lines, old_number) ||
        Highlight.plain(strip_marker(line.text))

    render(:context, old_number, new_number, html)
  end

  defp render(kind, old, new, html) do
    %{kind: kind, old: old, new: new, html: html, text: nil}
  end

  defp fragment(fragments, number, text) do
    lookup(fragments, number) || Highlight.plain(strip_marker(text))
  end

  # A nil line number (a note, or a side an added/deleted line does not have)
  # never matches, so Map.fetch returns :error instead of raising.
  defp lookup(_fragments, nil), do: nil

  defp lookup(fragments, number) do
    case Map.fetch(fragments, number) do
      {:ok, html} -> html
      :error -> nil
    end
  end

  # GitDiff keeps the diff marker in the line text: " " context, "+" added,
  # "-" removed.
  defp strip_marker(""), do: ""
  defp strip_marker(text), do: binary_part(text, 1, byte_size(text) - 1)

  defp to_integer(nil), do: nil
  defp to_integer(number), do: String.to_integer(number)
end

defmodule Tackle.Web.Anchor do
  @moduledoc """
  Where a question to the assistant was asked: a file, one side of the diff, and
  one line or a range of lines.

  A question is asked about a *place in the diff*, and its answer is shown there,
  so that place is part of the conversation rather than of the wording. This
  module owns its shape and the few questions the UI asks about it: where a thread
  hangs, whether a line is part of a live selection, what to call the selection,
  and how a shift-click extends one.

  A review comment is anchored the same way by `Tackle.Web.Review`, but is always
  a single line. The two are deliberately different values: a comment is attached
  to a line, while a question may cover a range the reviewer selected, and only
  the question needs that distinction.

  The anchor is not the browser tab's: `Tackle.Web.AgentConversation` persists it
  with the transcript, so every viewer of a pull request places the answer the
  same way and a reload keeps it there.
  """

  @typedoc "One line of one side of a diff, which is also a review comment's anchor."
  @type line :: {String.t(), :new | :old, pos_integer()}

  @typedoc "An inclusive range of lines on one side of one file."
  @type range :: {String.t(), :new | :old, pos_integer(), pos_integer()}

  @typedoc "Where a question was asked: one line, a range, or the whole pull request."
  @type at :: line() | range() | :general

  @doc "The anchor of a question about the pull request as a whole."
  @spec general() :: :general
  def general, do: :general

  @doc """
  Builds the anchor of a question about one line, or an inclusive range of lines.

  `last` defaults to `first`, and the range is normalized so `first` is the
  smaller line. A range of one line is stored as the single-line shape, so the
  renderer and the store never have to ask which form they were handed.
  """
  @spec new(String.t(), :new | :old, pos_integer(), pos_integer() | nil) :: line() | range()
  def new(path, side, first, last \\ nil)
      when is_binary(path) and side in [:new, :old] and is_integer(first) and first > 0 do
    last = if is_integer(last) and last > 0, do: last, else: first
    low = min(first, last)
    high = max(first, last)

    if low == high, do: {path, side, low}, else: {path, side, low, high}
  end

  @doc """
  The line a question's thread is rendered under: the last line of its range.

  Grouping by the last line is what puts an answer after the end of the selection
  it is about — the line a reviewer reading top to bottom reaches last — while the
  thread still remembers the whole range in `t:at/0`.
  """
  @spec key(at() | term()) :: line() | :general
  def key({path, side, line})
      when is_binary(path) and side in [:new, :old] and is_integer(line) and line > 0 do
    {path, side, line}
  end

  def key({path, side, _first, last})
      when is_binary(path) and side in [:new, :old] and is_integer(last) and last > 0 do
    {path, side, last}
  end

  def key(_other), do: :general

  @doc "Whether a question was asked about more than one line."
  @spec range?(at() | term()) :: boolean()
  def range?({_path, _side, _first, _last}), do: true
  def range?(_anchor), do: false

  @doc """
  Whether a line is inside the anchor.

  This is what marks the lines of a selection while a question is being written,
  so the reviewer can see the region the assistant will be told about.
  """
  @spec contains?(at() | term(), String.t(), :new | :old, integer() | nil) :: boolean()
  def contains?({path, side, line}, path, side, line), do: true

  def contains?({path, side, first, last}, path, side, line) when is_integer(line) do
    line >= first and line <= last
  end

  def contains?(_anchor, _path, _side, _line), do: false

  @doc """
  A short description of the anchor for the reader: `"line 12"`,
  `"lines 12-15"`, or `"this pull request"`.

  The question's wording and the form above it both name the selection with this,
  so they cannot describe it differently.
  """
  @spec label(at()) :: String.t()
  def label(:general), do: "this pull request"
  def label({_path, _side, line}), do: "line #{line}"
  def label({_path, _side, first, last}), do: "lines #{first}-#{last}"

  @doc """
  Extends a selection to `line`, which is what a shift-click does.

  Extending only makes sense within one file and one side of the diff: a range
  that spanned a rename, or mixed a removed line with an added one, would not name
  a region of any single file. A shift-click that would do that starts a fresh
  one-line anchor instead, so the selection a reviewer sees is always a region
  they can reason about.
  """
  @spec extend(at() | nil, String.t(), :new | :old, pos_integer()) :: line() | range()
  def extend({path, side, first, last}, path, side, line) do
    new(path, side, min(first, line), max(last, line))
  end

  def extend({path, side, line}, path, side, other) do
    new(path, side, min(line, other), max(line, other))
  end

  def extend(_anchor, path, side, line), do: new(path, side, line)
end

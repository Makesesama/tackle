defmodule Tackle.CLI.TUI.History do
  @moduledoc """
  In-memory prompt history for the composer.

  An entry is a whole draft — its text and the paste labels it holds — not just
  the text, so recalling a prompt that mentioned a collapsed paste puts the
  labels back as labels and the payloads expand again on the next submission.

  Entries are kept newest first so `previous/2` walks toward older prompts and
  `next/1` walks back. Recording ignores `nil` (a draft that is only
  whitespace, as `Tackle.CLI.TUI.Pastes.normalize/1` reports) and a draft whose
  text repeats the newest entry, so resubmitting the same prompt does not fill
  the list with copies. The list is capped, dropping oldest entries first.

  Browsing is a mode rather than a value: `index` is `nil` while the user is
  drafting and a `0`-based position into `entries` while a recalled prompt is
  shown, and `draft` remembers the draft that was in the composer when browsing
  began. That is what lets `next/1` hand the draft back once the newest entry is
  passed, instead of losing it.

  Nothing here touches the composer or the terminal; the module only describes
  which draft `Tackle.CLI.TUI.Composer` should load next.
  """

  alias Tackle.CLI.TUI.Pastes.Draft

  @max_entries 100

  @typedoc "A recalled position, or `nil` while the user is drafting."
  @type index :: non_neg_integer() | nil

  @type t :: %__MODULE__{
          entries: [Draft.t()],
          index: index(),
          draft: Draft.t() | nil
        }

  defstruct entries: [], index: nil, draft: nil

  @doc "Returns an empty history."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Whether a recalled prompt, rather than the live draft, is showing."
  @spec browsing?(t()) :: boolean()
  def browsing?(%__MODULE__{index: index}), do: index != nil

  @doc """
  Records `draft` as the newest prompt.

  `nil` (a blank draft) and a text that repeats the newest entry are ignored.
  Recording also ends any browsing, because a submitted prompt is no longer
  being recalled.
  """
  @spec record(t(), Draft.t() | nil) :: t()
  def record(%__MODULE__{} = history, nil), do: history

  def record(%__MODULE__{} = history, %Draft{text: text} = draft) do
    case String.trim(text) do
      "" -> history
      prompt -> %{history | entries: push(history.entries, draft, prompt), index: nil, draft: nil}
    end
  end

  @doc """
  Steps to the next older entry.

  `current` is captured as the draft the first time browsing starts, so it can
  be restored later. Returns `:none` when there is nothing older—including an
  empty history—so the caller can leave the composer untouched.
  """
  @spec previous(t(), Draft.t()) :: :none | {t(), Draft.t()}
  def previous(%__MODULE__{entries: []}, _current), do: :none

  def previous(%__MODULE__{entries: entries, index: index} = history, current) do
    target = if index == nil, do: 0, else: index + 1

    if target >= length(entries) do
      :none
    else
      draft = history.draft || current
      {%{history | index: target, draft: draft}, Enum.at(entries, target)}
    end
  end

  @doc """
  Steps toward the newest entry.

  Stepping past the newest entry leaves browsing and returns the draft captured
  when browsing began. Returns `:none` when the user is not browsing, so a Down
  press can still move the cursor in a draft.
  """
  @spec next(t()) :: :none | {t(), Draft.t()}
  def next(%__MODULE__{index: nil}), do: :none

  def next(%__MODULE__{index: 0} = history),
    do: {%{history | index: nil, draft: nil}, history.draft || Draft.new()}

  def next(%__MODULE__{entries: entries, index: index} = history),
    do: {%{history | index: index - 1}, Enum.at(entries, index - 1)}

  @doc "Ends browsing without changing the entries or the loaded text."
  @spec leave_browsing(t()) :: t()
  def leave_browsing(%__MODULE__{} = history), do: %{history | index: nil, draft: nil}

  defp push([%Draft{text: text} | _rest] = entries, _draft, text), do: entries
  defp push(entries, draft, _text), do: Enum.take([draft | entries], @max_entries)
end

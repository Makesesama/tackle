defmodule Tackle.CLI.TUI.History do
  @moduledoc """
  In-memory prompt history for the composer.

  Entries are kept newest first so `previous/2` walks toward older prompts and
  `next/1` walks back. Recording trims whitespace, ignores empty prompts, and
  drops a prompt identical to the newest entry, so resubmitting the same text
  does not fill the list with copies. The list is capped, dropping oldest
  entries first.

  Browsing is a mode rather than a value: `index` is `nil` while the user is
  drafting and a `0`-based position into `entries` while a recalled prompt is
  shown, and `draft` remembers what was in the composer when browsing began.
  That is what lets `next/1` hand the draft back once the newest entry is
  passed, instead of losing it.

  Nothing here touches the composer or the terminal; the module only describes
  which text `Tackle.CLI.TUI.Composer` should load next.
  """

  @max_entries 100

  @typedoc "A recalled position, or `nil` while the user is drafting."
  @type index :: non_neg_integer() | nil

  @type t :: %__MODULE__{
          entries: [String.t()],
          index: index(),
          draft: String.t() | nil
        }

  defstruct entries: [], index: nil, draft: nil

  @doc "Returns an empty history."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Whether a recalled prompt, rather than the live draft, is showing."
  @spec browsing?(t()) :: boolean()
  def browsing?(%__MODULE__{index: index}), do: index != nil

  @doc """
  Records `text` as the newest prompt.

  Blank text and a repeat of the newest entry are ignored. Recording also ends
  any browsing, because a submitted prompt is no longer being recalled.
  """
  @spec record(t(), String.t()) :: t()
  def record(%__MODULE__{} = history, text) do
    case String.trim(text) do
      "" -> history
      prompt -> %{history | entries: push(history.entries, prompt), index: nil, draft: nil}
    end
  end

  @doc """
  Steps to the next older entry.

  `current` is captured as the draft the first time browsing starts, so it can
  be restored later. Returns `:none` when there is nothing older—including an
  empty history—so the caller can leave the composer untouched.
  """
  @spec previous(t(), String.t()) :: :none | {t(), String.t()}
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
  @spec next(t()) :: :none | {t(), String.t()}
  def next(%__MODULE__{index: nil}), do: :none

  def next(%__MODULE__{index: 0} = history),
    do: {%{history | index: nil, draft: nil}, history.draft || ""}

  def next(%__MODULE__{entries: entries, index: index} = history),
    do: {%{history | index: index - 1}, Enum.at(entries, index - 1)}

  @doc "Ends browsing without changing the entries or the loaded text."
  @spec leave_browsing(t()) :: t()
  def leave_browsing(%__MODULE__{} = history), do: %{history | index: nil, draft: nil}

  defp push([prompt | _rest] = entries, prompt), do: entries
  defp push(entries, prompt), do: Enum.take([prompt | entries], @max_entries)
end

defmodule Tackle.CLI.TUI.Picker do
  @moduledoc """
  Search-first list shared by the model, thinking, and settings menus.

  A picker owns an ordered item list, a live query, and a selection. Items carry
  what they print separately from what they match: `:primary` and `:secondary`
  are the row, while `:search` is the text a query is tested against. The model
  menu uses that split to search `provider provider/id id` instead of the bare
  model id, so a provider-qualified query ranks above a proxy id such as
  `openrouter/openai/gpt-5`.

  Filtering is fuzzy. An exact substring outranks a scattered subsequence, and a
  tighter match outranks a looser one, so a typed prefix keeps its item on top
  and clearing the query restores the authored order rather than a recency
  order.

  The query is a plain string rather than a text-input widget: menus are short,
  and this keeps query, filtering, and selection in one pure struct that tests
  can drive without a terminal.
  """

  @typedoc """
  One menu row.

  `:id` is what selecting the row means (a model ref, a thinking level, a
  setting name); `:marker` is a leading glyph such as a current-value tick.
  """
  @type item :: %{
          id: term(),
          primary: String.t(),
          secondary: String.t() | nil,
          marker: String.t() | nil,
          search: String.t() | nil
        }

  @type t :: %__MODULE__{
          items: [item()],
          query: String.t(),
          selected: non_neg_integer()
        }

  defstruct items: [], query: "", selected: 0

  @doc "Builds a picker over `items`, optionally starting from a query."
  @spec new([item()], String.t()) :: t()
  def new(items, query \\ "") when is_list(items) do
    %__MODULE__{items: items, query: query}
  end

  @doc "Appends typed text to the query and returns the selection to the top."
  @spec insert(t(), String.t()) :: t()
  def insert(%__MODULE__{} = picker, text) when is_binary(text) do
    %{picker | query: picker.query <> text, selected: 0}
  end

  @doc "Removes the last grapheme from the query."
  @spec backspace(t()) :: t()
  def backspace(%__MODULE__{query: ""} = picker), do: picker

  def backspace(%__MODULE__{} = picker) do
    query = picker.query |> String.graphemes() |> Enum.drop(-1) |> Enum.join()
    %{picker | query: query, selected: 0}
  end

  @doc "Moves the selection by `delta`, clamped to the matching items."
  @spec move(t(), integer()) :: t()
  def move(%__MODULE__{} = picker, delta) when is_integer(delta) do
    count = length(filtered(picker))
    %{picker | selected: clamp(picker.selected + delta, 0, max(count - 1, 0))}
  end

  @doc "Returns the items matching the current query, in ranked order."
  @spec filtered(t()) :: [item()]
  def filtered(%__MODULE__{items: items, query: query}), do: filter(items, query)

  @doc "Returns the highlighted item, or nil when nothing matches."
  @spec selected(t()) :: item() | nil
  def selected(%__MODULE__{} = picker) do
    items = filtered(picker)
    Enum.at(items, clamp(picker.selected, 0, max(length(items) - 1, 0)))
  end

  @doc "Renders one row as `marker  primary  secondary`."
  @spec row(item()) :: String.t()
  def row(item) do
    [item[:marker] || " ", item[:primary], item[:secondary]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("  ")
  end

  @doc """
  Filters items by a fuzzy query.

  An empty query is the identity filter, which keeps the authored order stable
  so spatial memory of the list is not reshuffled between visits.
  """
  @spec filter([item()], String.t()) :: [item()]
  def filter(items, query) when is_list(items) do
    needle = query |> String.trim() |> String.downcase()

    if needle == "" do
      items
    else
      items
      |> Enum.map(&{rank(&1, needle), &1})
      |> Enum.reject(fn {rank, _item} -> is_nil(rank) end)
      |> Enum.sort_by(fn {rank, _item} -> rank end)
      |> Enum.map(fn {_rank, item} -> item end)
    end
  end

  # Substring matches rank above scattered subsequences; within each tier a
  # tighter match at an earlier position wins, then a shorter item.
  defp rank(item, needle) do
    text = item |> search_text() |> String.downcase()
    size = String.length(text)

    case :binary.match(text, needle) do
      {position, matched} -> {0, position, matched, size}
      :nomatch -> subsequence_rank(text, needle, size)
    end
  end

  defp subsequence_rank(text, needle, size) do
    case span(text, needle) do
      nil -> nil
      {first, last} -> {1, last - first, first, size}
    end
  end

  defp search_text(item) do
    item[:search] || Enum.join(Enum.reject([item[:primary], item[:secondary]], &is_nil/1), " ")
  end

  # Returns the first and last grapheme index of `needle` within `text` when it
  # appears in order but not contiguously.
  defp span(text, needle) do
    do_span(String.graphemes(text), String.graphemes(needle), 0, nil, nil)
  end

  defp do_span(_text, [], _index, nil, _last), do: nil
  defp do_span(_text, [], _index, first, last), do: {first, last}
  defp do_span([], _needle, _index, _first, _last), do: nil

  defp do_span([char | text], [char | needle], index, first, _last),
    do: do_span(text, needle, index + 1, first || index, index)

  defp do_span([_char | text], needle, index, first, last),
    do: do_span(text, needle, index + 1, first, last)

  defp clamp(value, minimum, maximum), do: value |> max(minimum) |> min(maximum)
end

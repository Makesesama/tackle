defmodule Tackle.CLI.TUI.Conversation do
  @moduledoc """
  Owns the TUI conversation cache, layout dimensions, and row scrolling.

  Sections are refreshed independently so streaming deltas only rebuild the
  section they affect. The cache stores typed `MessageView.Entry` values and
  their primitive widget groups; `WidgetList` receives only the bounded slice
  intersecting the current viewport.
  """

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph
  alias Tackle.CLI.TUI.MessageView

  @mouse_scroll_rows 3
  @sections [:settled, :pending, :tools, :thinking, :response, :error]

  @typedoc "Sections whose entries can be refreshed independently."
  @type section :: :settled | :pending | :tools | :thinking | :response | :error

  @typedoc "Cached typed entries and their rendered widget groups for a section."
  @type section_cache :: %{
          entries: [MessageView.t()],
          groups: [[MessageView.widget_item()]]
        }

  @type t :: %__MODULE__{
          width: pos_integer(),
          viewport_height: non_neg_integer(),
          rect: Rect.t(),
          sections: %{optional(section()) => section_cache()},
          items: [MessageView.widget_item()],
          visible_items: [MessageView.widget_item()],
          visible_offset: non_neg_integer(),
          content_height: non_neg_integer(),
          scroll_offset: non_neg_integer(),
          follow?: boolean()
        }

  defstruct width: 1,
            viewport_height: 0,
            rect: %Rect{},
            sections: %{},
            items: [],
            visible_items: [],
            visible_offset: 0,
            content_height: 0,
            scroll_offset: 0,
            follow?: true

  @doc "Creates an empty conversation model for the conversation panel rect."
  @spec new(Rect.t()) :: t()
  def new(%Rect{} = rect) do
    %__MODULE__{
      width: max(rect.width - 2, 1),
      viewport_height: max(rect.height - 2, 0),
      rect: rect,
      sections: empty_sections()
    }
  end

  @doc "Rebuilds dimensions while retaining row position and follow policy."
  @spec resize(t(), Rect.t()) :: t()
  def resize(%__MODULE__{} = conversation, %Rect{} = rect) do
    resized = new(rect)
    %{resized | scroll_offset: conversation.scroll_offset, follow?: conversation.follow?}
  end

  @doc "Refreshes selected sections and recalculates the complete row model."
  @spec refresh(t(), map()) :: t()
  @spec refresh(t(), map(), [section()]) :: t()
  def refresh(%__MODULE__{} = conversation, state, sections \\ @sections) do
    section_cache =
      Enum.reduce(sections, Map.merge(empty_sections(), conversation.sections), fn section,
                                                                                   caches ->
        Map.put(caches, section, build_section(state, section, conversation.width))
      end)

    groups =
      @sections
      |> Enum.flat_map(fn section ->
        section_cache
        |> Map.fetch!(section)
        |> Map.fetch!(:groups)
      end)

    groups =
      if groups == [],
        do: [MessageView.render_entry(MessageView.welcome_entry(), conversation.width)],
        else: groups

    items =
      groups
      |> Enum.intersperse([spacer_item()])
      |> List.flatten()

    content_height = Enum.reduce(items, 0, fn {_widget, height}, total -> total + height end)
    max_offset = max(content_height - conversation.viewport_height, 0)

    scroll_offset =
      if conversation.follow?,
        do: max_offset,
        else: min(conversation.scroll_offset, max_offset)

    conversation = %{
      conversation
      | sections: section_cache,
        items: items,
        content_height: content_height,
        scroll_offset: scroll_offset,
        follow?: conversation.follow? or scroll_offset == max_offset
    }

    put_visible(conversation)
  end

  @doc "Scrolls by a row delta and updates follow-to-latest state."
  @spec scroll(t(), integer()) :: t()
  def scroll(%__MODULE__{} = conversation, delta) when is_integer(delta) do
    max_offset = max(conversation.content_height - conversation.viewport_height, 0)
    scroll_offset = conversation.scroll_offset |> Kernel.+(delta) |> max(0) |> min(max_offset)

    conversation
    |> Map.merge(%{scroll_offset: scroll_offset, follow?: scroll_offset == max_offset})
    |> put_visible()
  end

  @doc "Scrolls to the oldest or newest conversation row."
  @spec scroll_to(t(), :start | :end) :: t()
  def scroll_to(%__MODULE__{} = conversation, :start) do
    conversation |> Map.merge(%{scroll_offset: 0, follow?: false}) |> put_visible()
  end

  def scroll_to(%__MODULE__{} = conversation, :end) do
    max_offset = max(conversation.content_height - conversation.viewport_height, 0)

    conversation
    |> Map.merge(%{scroll_offset: max_offset, follow?: true})
    |> put_visible()
  end

  @doc "Returns the number of rows moved by one page action."
  @spec page_size(t()) :: pos_integer()
  def page_size(%__MODULE__{} = conversation), do: max(conversation.viewport_height - 1, 1)

  @doc "Returns whether a terminal coordinate lies within the conversation panel."
  @spec contains?(t(), integer(), integer()) :: boolean()
  def contains?(%__MODULE__{rect: rect}, x, y) when is_integer(x) and is_integer(y) do
    x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height
  end

  def contains?(_conversation, _x, _y), do: false

  @doc "Returns the panel title for the current scroll position."
  @spec title(t()) :: String.t()
  def title(%__MODULE__{} = conversation) do
    max_offset = max(conversation.content_height - conversation.viewport_height, 0)

    cond do
      max_offset == 0 -> " Conversation "
      conversation.follow? -> " Conversation · latest "
      true -> " Conversation · #{round(conversation.scroll_offset / max_offset * 100)}% "
    end
  end

  @doc false
  @spec mouse_scroll_rows() :: pos_integer()
  def mouse_scroll_rows, do: @mouse_scroll_rows

  defp empty_sections do
    Map.new(@sections, &{&1, %{entries: [], groups: []}})
  end

  defp build_section(state, section, width) do
    entries = MessageView.section_entries(state, section)
    groups = Enum.map(entries, &MessageView.render_entry(&1, width))
    %{entries: entries, groups: groups}
  end

  defp spacer_item, do: {%Paragraph{text: ""}, 1}

  defp put_visible(%__MODULE__{} = conversation) do
    {remaining_items, visible_offset} =
      drop_scrolled_items(conversation.items, conversation.scroll_offset)

    visible_items =
      take_visible_items(remaining_items, conversation.viewport_height + visible_offset)

    %{conversation | visible_items: visible_items, visible_offset: visible_offset}
  end

  defp drop_scrolled_items([{_widget, height} | items], offset) when offset >= height,
    do: drop_scrolled_items(items, offset - height)

  defp drop_scrolled_items(items, offset), do: {items, offset}

  defp take_visible_items(_items, rows) when rows <= 0, do: []
  defp take_visible_items([], _rows), do: []

  defp take_visible_items([{_widget, height} = item | items], rows),
    do: [item | take_visible_items(items, rows - height)]
end

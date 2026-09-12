defmodule Tackle.CLI.TUI.Conversation do
  @moduledoc """
  Owns the transcript cache, layout dimensions, and row scrolling.

  Sections are refreshed independently, so streaming deltas only rebuild the
  section they affect. The cache keeps typed entries with their full retained
  source; immutable native cells cache layout and only viewport paint crosses
  back to the terminal bridge. A reading
  anchor identifies an entry and an offset within that entry, so streaming
  updates, reasoning collapse, and terminal resize do not silently replace the
  passage the user is reading.
  """

  alias ExRatatui.Layout.Rect
  alias Tackle.CLI.TUI.MessageView
  alias Tackle.CLI.Widgets.Conversation, as: NativeConversation

  @mouse_scroll_rows 3
  @sections [:settled, :pending, :turn, :error]
  @max_search_matches 200

  @typedoc "Sections whose entries can be refreshed independently."
  @type section :: :settled | :pending | :turn | :error

  @typedoc "Cached typed entries and their rendered widget groups for a section."
  @type section_cache :: %{
          entries: [MessageView.t()],
          width: pos_integer() | nil,
          groups: [[MessageView.widget_item()]],
          item_ids: [[String.t()]]
        }

  @typedoc "A stable reading position: an entry id plus a row offset inside it."
  @type anchor :: %{id: String.t(), offset: non_neg_integer()}

  @type search_match :: %{
          id: String.t(),
          entry: MessageView.t(),
          preview: String.t()
        }

  @type t :: %__MODULE__{
          native: reference() | nil,
          selected_entry: String.t() | nil,
          width: pos_integer(),
          viewport_height: non_neg_integer(),
          rect: Rect.t(),
          sections: %{optional(section()) => section_cache()},
          items: [MessageView.widget_item()],
          item_ids: [String.t() | nil],
          visible_items: [MessageView.widget_item()],
          visible_offset: non_neg_integer(),
          content_height: non_neg_integer(),
          scroll_offset: non_neg_integer(),
          follow?: boolean(),
          new_output?: boolean(),
          anchor: anchor() | nil
        }

  defstruct native: nil,
            selected_entry: nil,
            width: 1,
            viewport_height: 0,
            rect: %Rect{},
            sections: %{},
            items: [],
            item_ids: [],
            visible_items: [],
            visible_offset: 0,
            content_height: 0,
            scroll_offset: 0,
            follow?: true,
            new_output?: false,
            anchor: nil

  @doc "Creates an empty conversation model for the transcript rect."
  @spec new(Rect.t()) :: t()
  def new(%Rect{} = rect) do
    {native, 0} = NativeConversation.assemble([], max(rect.width, 1))

    %__MODULE__{
      native: native,
      width: max(rect.width, 1),
      viewport_height: max(rect.height, 0),
      rect: rect,
      sections: empty_sections()
    }
  end

  @doc "Rebuilds dimensions while retaining cached rows and reading position."
  @spec resize(t(), Rect.t()) :: t()
  def resize(%__MODULE__{} = conversation, %Rect{} = rect) do
    anchor = reading_anchor(conversation)
    width = max(rect.width, 1)

    {sections, items, item_ids, native, content_height} =
      if width == conversation.width do
        {conversation.sections, conversation.items, conversation.item_ids, conversation.native,
         conversation.content_height}
      else
        sections =
          Map.new(conversation.sections, fn {section, cache} ->
            {section, cache_entries(cache.entries, width, cache)}
          end)

        {items, item_ids} = build_items(sections, width)
        {native, height} = NativeConversation.assemble(items, width)
        {sections, items, item_ids, native, height}
      end

    resized = %{
      conversation
      | width: width,
        rect: rect,
        viewport_height: max(rect.height, 0),
        native: native,
        selected_entry: conversation.selected_entry,
        sections: sections,
        items: items,
        item_ids: item_ids,
        content_height: content_height,
        follow?: conversation.follow?,
        new_output?: conversation.new_output?,
        anchor: anchor
    }

    max_offset = max(resized.content_height - resized.viewport_height, 0)

    scroll_offset =
      cond do
        resized.follow? ->
          max_offset

        anchor ->
          anchor_offset(resized.item_ids, resized.items, anchor) ||
            min(conversation.scroll_offset, max_offset)

        true ->
          min(conversation.scroll_offset, max_offset)
      end

    resized
    |> Map.merge(%{scroll_offset: scroll_offset, follow?: conversation.follow?})
    |> put_anchor()
    |> put_visible()
  end

  @doc "Refreshes selected sections and recalculates the complete row model."
  @spec refresh(t(), map()) :: t()
  @spec refresh(t(), map(), [section()]) :: t()
  def refresh(%__MODULE__{} = conversation, state, sections \\ @sections) do
    old_content_height = conversation.content_height
    preserved_anchor = reading_anchor(conversation)

    section_cache =
      Enum.reduce(sections, Map.merge(empty_sections(), conversation.sections), fn section,
                                                                                   caches ->
        Map.put(
          caches,
          section,
          build_section(state, section, conversation.width, caches[section])
        )
      end)

    {items, item_ids} = build_items(section_cache, conversation.width)
    {native, content_height} = NativeConversation.assemble(items, conversation.width)
    max_offset = max(content_height - conversation.viewport_height, 0)

    anchored_offset = anchor_offset(item_ids, items, preserved_anchor)

    {scroll_offset, follow?} =
      if conversation.follow? do
        {max_offset, true}
      else
        {anchored_offset || min(conversation.scroll_offset, max_offset), false}
      end

    # New output means rows were appended below the reading position, which
    # leaves the anchored offset unchanged. Content inserted above the reading
    # position (expanding an earlier card) shifts the anchor and is not output.
    new_output? =
      if follow? do
        false
      else
        conversation.new_output? or
          (content_height > old_content_height and anchored_offset == conversation.scroll_offset)
      end

    refreshed = %{
      conversation
      | native: native,
        selected_entry: Map.get(state, :selected_entry),
        sections: section_cache,
        items: items,
        item_ids: item_ids,
        content_height: content_height,
        scroll_offset: scroll_offset,
        follow?: follow?,
        new_output?: new_output?,
        anchor: nil
    }

    refreshed
    |> put_anchor()
    |> put_visible()
  end

  @doc "Scrolls by a row delta and updates follow-to-latest state."
  @spec scroll(t(), integer()) :: t()
  def scroll(%__MODULE__{} = conversation, delta) when is_integer(delta) do
    max_offset = max(conversation.content_height - conversation.viewport_height, 0)
    scroll_offset = conversation.scroll_offset |> Kernel.+(delta) |> max(0) |> min(max_offset)
    follow? = scroll_offset == max_offset

    conversation
    |> Map.merge(%{
      scroll_offset: scroll_offset,
      follow?: follow?,
      new_output?: if(follow?, do: false, else: conversation.new_output?)
    })
    |> put_anchor()
    |> put_visible()
  end

  @doc "Scrolls to the oldest or newest conversation row."
  @spec scroll_to(t(), :start | :end) :: t()
  def scroll_to(%__MODULE__{} = conversation, :start) do
    conversation
    |> Map.merge(%{
      scroll_offset: 0,
      follow?: false,
      new_output?: conversation.content_height > conversation.viewport_height
    })
    |> put_anchor()
    |> put_visible()
  end

  def scroll_to(%__MODULE__{} = conversation, :end) do
    max_offset = max(conversation.content_height - conversation.viewport_height, 0)

    conversation
    |> Map.merge(%{scroll_offset: max_offset, follow?: true, new_output?: false, anchor: nil})
    |> put_visible()
  end

  @doc "Reveals a stable entry without changing the active agent turn."
  @spec scroll_to_entry(t(), String.t()) :: t()
  def scroll_to_entry(%__MODULE__{} = conversation, id) when is_binary(id) do
    case entry_offset(conversation.item_ids, conversation.items, id) do
      nil ->
        conversation

      offset ->
        conversation
        |> Map.merge(%{scroll_offset: offset, follow?: false, new_output?: false})
        |> put_anchor()
        |> put_visible()
    end
  end

  @doc "Returns the number of rows moved by one page action."
  @spec page_size(t()) :: pos_integer()
  def page_size(%__MODULE__{} = conversation), do: max(conversation.viewport_height - 1, 1)

  @doc """
  Scrolls the minimum amount that brings an entry fully into view.

  A no-op when the entry already fits, so stepping through adjacent entries
  moves the selection without dragging the transcript on every keypress.
  """
  @spec scroll_into_view(t(), String.t()) :: t()
  def scroll_into_view(%__MODULE__{} = conversation, id) when is_binary(id) do
    case entry_span(conversation, id) do
      nil ->
        conversation

      {top, height} ->
        bottom = top + height
        viewport = conversation.viewport_height
        max_offset = max(conversation.content_height - viewport, 0)

        cond do
          top < conversation.scroll_offset ->
            move_to(conversation, top, max_offset)

          bottom > conversation.scroll_offset + viewport ->
            move_to(conversation, bottom - viewport, max_offset)

          true ->
            conversation
        end
    end
  end

  @doc "Returns the section holding an entry id, or nil when it is not cached."
  @spec section_of(t(), String.t()) :: section() | nil
  def section_of(%__MODULE__{} = conversation, id) when is_binary(id) do
    Enum.find(@sections, fn section ->
      conversation.sections
      |> Map.get(section, %{entries: []})
      |> Map.fetch!(:entries)
      |> Enum.any?(&(&1.id == id))
    end)
  end

  @doc "Returns the cached entry for an id, or nil when it is not cached."
  @spec entry(t(), String.t()) :: MessageView.t() | nil
  def entry(%__MODULE__{} = conversation, id) when is_binary(id) do
    conversation |> entries() |> Enum.find(&(&1.id == id))
  end

  @doc "Returns whether a terminal coordinate lies within the transcript."
  @spec contains?(t(), integer(), integer()) :: boolean()
  def contains?(%__MODULE__{rect: rect}, x, y) when is_integer(x) and is_integer(y) do
    x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height
  end

  def contains?(_conversation, _x, _y), do: false

  @doc "Returns cached conversation entries in display order."
  @spec entries(t()) :: [MessageView.t()]
  def entries(%__MODULE__{} = conversation) do
    Enum.flat_map(@sections, fn section ->
      conversation.sections
      |> Map.get(section, %{entries: []})
      |> Map.fetch!(:entries)
    end)
  end

  @doc "Returns the complete retained source represented by the conversation."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{} = conversation) do
    conversation
    |> entries()
    |> Enum.map_join("\n\n", &MessageView.source_text/1)
  end

  @doc """
  Searches complete retained entry source, including hidden tool output.

  Matching is case-insensitive and returns at most #{@max_search_matches}
  results. Search scans retained entries synchronously; previews are sanitized
  for paint while the matched entry retains its raw source for copy actions.
  """
  @spec search(t(), String.t()) :: [search_match()]
  def search(%__MODULE__{} = conversation, query) when is_binary(query) do
    needle = query |> String.trim() |> String.downcase()

    if needle == "" do
      []
    else
      conversation
      |> entries()
      |> Stream.flat_map(&search_entry(&1, needle))
      |> Enum.take(@max_search_matches)
    end
  end

  defp search_entry(entry, needle) do
    source = MessageView.search_text(entry)

    if String.contains?(String.downcase(source), needle) do
      [
        %{
          id: entry.id,
          entry: entry,
          preview: MessageView.sanitize(search_preview(source, needle))
        }
      ]
    else
      []
    end
  end

  @doc "Returns the reading-back affordance text, or nil while following."
  @spec affordance(t()) :: String.t() | nil
  def affordance(%__MODULE__{new_output?: true}), do: "↓ New output · Ctrl+End latest"
  def affordance(%__MODULE__{follow?: false}), do: "↑ Reading back · Ctrl+End latest"
  def affordance(%__MODULE__{}), do: nil

  @doc """
  Slices widget items to the rows intersecting a viewport.

  Returns the visible cell handles and the row offset into the first cell.
  This metadata supports browsing and reading anchors; native conversation
  paint uses the complete immutable resource and its own viewport clipping.
  """
  @spec slice([MessageView.widget_item()], non_neg_integer(), non_neg_integer()) ::
          {[MessageView.widget_item()], non_neg_integer()}
  def slice(items, scroll_offset, viewport_height) do
    {remaining_items, visible_offset} = drop_scrolled_items(items, scroll_offset)
    {take_visible_items(remaining_items, viewport_height + visible_offset), visible_offset}
  end

  @doc false
  @spec mouse_scroll_rows() :: pos_integer()
  def mouse_scroll_rows, do: @mouse_scroll_rows

  defp empty_sections do
    Map.new(@sections, &{&1, %{entries: [], groups: [], item_ids: [], width: nil}})
  end

  @doc "Returns the native widget for this immutable transcript snapshot."
  @spec widget(t()) :: NativeConversation.t()
  def widget(%__MODULE__{} = conversation) do
    selected =
      for {id, index} <- Enum.with_index(conversation.item_ids),
          id && id == conversation.selected_entry,
          do: index

    %NativeConversation{
      state: conversation.native,
      scroll_offset: conversation.scroll_offset,
      selected: selected
    }
  end

  defp build_section(state, section, width, previous) do
    entries =
      state
      |> MessageView.section_entries(section)
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} -> %{entry | id: entry.id || "#{section}:#{index}"} end)

    cache_entries(entries, width, previous)
  end

  defp cache_entries(entries, width, previous) do
    cached =
      if Map.get(previous, :width) == width,
        do:
          Map.new(Enum.zip(previous.entries, previous.groups), fn {entry, group} ->
            {entry.id, {entry, group}}
          end),
        else: %{}

    groups =
      Enum.map(entries, fn entry ->
        case Map.get(cached, entry.id) do
          {^entry, group} -> group
          _ -> NativeConversation.cell(entry, width)
        end
      end)

    item_ids =
      Enum.zip(entries, groups)
      |> Enum.map(fn {entry, items} -> List.duplicate(entry.id, length(items)) end)

    %{entries: entries, groups: groups, item_ids: item_ids, width: width}
  end

  defp build_items(section_cache, width) do
    groups =
      Enum.flat_map(@sections, fn section ->
        cache = Map.fetch!(section_cache, section)
        Enum.zip(cache.groups, cache.item_ids)
      end)

    groups =
      if groups == [] do
        welcome = NativeConversation.cell(MessageView.welcome_entry(), width)
        [{welcome, List.duplicate("welcome", length(welcome))}]
      else
        groups
      end

    pairs =
      groups
      |> Enum.map(fn {group, ids} -> Enum.zip(group, ids) end)
      |> Enum.intersperse([{NativeConversation.spacer(width), nil}])
      |> List.flatten()

    items = Enum.map(pairs, fn {item, _id} -> item end)
    item_ids = Enum.map(pairs, fn {_item, id} -> id end)
    {items, item_ids}
  end

  defp put_visible(%__MODULE__{} = conversation) do
    {visible_items, visible_offset} =
      slice(conversation.items, conversation.scroll_offset, conversation.viewport_height)

    %{conversation | visible_items: visible_items, visible_offset: visible_offset}
  end

  defp put_anchor(%__MODULE__{follow?: true} = conversation), do: %{conversation | anchor: nil}

  defp put_anchor(%__MODULE__{} = conversation),
    do: %{conversation | anchor: capture_anchor(conversation)}

  defp reading_anchor(%__MODULE__{follow?: true}), do: nil

  defp reading_anchor(%__MODULE__{} = conversation),
    do: conversation.anchor || capture_anchor(conversation)

  defp capture_anchor(%__MODULE__{items: [], item_ids: []}), do: nil

  defp capture_anchor(%__MODULE__{items: items, item_ids: item_ids, scroll_offset: offset}) do
    {index, within} = locate_offset(items, offset)
    id = Enum.at(item_ids, index) || nearest_id(item_ids, index)

    if is_binary(id) do
      first = Enum.find_index(item_ids, &(&1 == id))

      %{id: id, offset: prior_row_count(items, first, index) + within}
    end
  end

  defp prior_row_count(_items, first, index) when first >= index, do: 0

  defp prior_row_count(items, first, index) do
    items
    |> Enum.slice(first, index - first)
    |> Enum.reduce(0, fn {_, height}, sum -> sum + height end)
  end

  # Returns the item index containing `offset` and the row offset within it.
  # An offset at or beyond the end of the transcript maps to the final item.
  defp locate_offset(items, offset) do
    result =
      items
      |> Enum.with_index()
      |> Enum.reduce_while(offset, fn {{_item, height}, index}, remaining ->
        height = max(height, 1)

        if remaining < height do
          {:halt, {index, remaining}}
        else
          {:cont, remaining - height}
        end
      end)

    case result do
      {index, within} -> {index, within}
      _remaining -> {max(length(items) - 1, 0), offset}
    end
  end

  # Spacer rows have no entry id. Anchor to the next real entry, falling back
  # to the previous one, so resize does not jump to an unrelated passage.
  defp nearest_id(item_ids, index) do
    forward =
      index..(length(item_ids) - 1)
      |> Enum.find_value(fn position -> binary_at(item_ids, position) end)

    forward ||
      (index - 1)..0
      |> Enum.find_value(fn position -> binary_at(item_ids, position) end)
  end

  defp binary_at(item_ids, position) do
    case Enum.at(item_ids, position) do
      id when is_binary(id) -> id
      _none -> nil
    end
  end

  defp anchor_offset(_item_ids, _items, nil), do: nil

  defp anchor_offset(item_ids, items, %{id: id, offset: offset}) do
    case Enum.find_index(item_ids, &(&1 == id)) do
      nil ->
        nil

      index ->
        height =
          Enum.zip(item_ids, items)
          |> Enum.drop(index)
          |> Enum.take_while(fn {item_id, _} -> item_id == id end)
          |> Enum.reduce(0, fn {_, {_, height}}, total -> total + height end)

        preceding =
          items |> Enum.take(index) |> Enum.reduce(0, fn {_item, h}, total -> total + h end)

        preceding + min(offset, max(height - 1, 0))
    end
  end

  defp entry_offset(item_ids, items, id) do
    case Enum.find_index(item_ids, &(&1 == id)) do
      nil ->
        nil

      index ->
        items |> Enum.take(index) |> Enum.reduce(0, fn {_item, h}, total -> total + h end)
    end
  end

  # Returns the row offset and height of an entry, or nil when it is absent.
  defp entry_span(%__MODULE__{} = conversation, id) do
    case Enum.find_index(conversation.item_ids, &(&1 == id)) do
      nil ->
        nil

      index ->
        top =
          conversation.items
          |> Enum.take(index)
          |> Enum.reduce(0, fn {_item, h}, offset -> offset + h end)

        height =
          conversation.item_ids
          |> Enum.zip(conversation.items)
          |> Enum.drop(index)
          |> Enum.take_while(fn {item_id, _item} -> item_id == id end)
          |> Enum.reduce(0, fn {_item_id, {_widget, h}}, total -> total + h end)

        {top, height}
    end
  end

  defp move_to(conversation, offset, max_offset) do
    scroll_offset = clamp(offset, 0, max_offset)

    conversation
    |> Map.merge(%{scroll_offset: scroll_offset, follow?: false, new_output?: false})
    |> put_anchor()
    |> put_visible()
  end

  defp clamp(value, minimum, maximum), do: value |> max(minimum) |> min(maximum)

  defp search_preview(source, needle) do
    line =
      source
      |> String.split("\n")
      |> Enum.find("", &String.contains?(String.downcase(&1), needle))
      |> String.trim()

    if String.length(line) > 120, do: String.slice(line, 0, 119) <> "…", else: line
  end

  defp drop_scrolled_items([{_widget, height} | items], offset) when offset >= height,
    do: drop_scrolled_items(items, offset - height)

  defp drop_scrolled_items(items, offset), do: {items, offset}

  defp take_visible_items(_items, rows) when rows <= 0, do: []
  defp take_visible_items([], _rows), do: []

  defp take_visible_items([{_widget, height} = item | items], rows),
    do: [item | take_visible_items(items, rows - height)]
end

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
          item_ids: [[String.t()]],
          cells: %{optional(String.t()) => map()}
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
          text_selection: Tackle.CLI.TUI.TextSelection.t() | nil,
          selected_entry: String.t() | nil,
          width: pos_integer(),
          viewport_height: non_neg_integer(),
          rect: Rect.t(),
          sections: %{optional(section()) => section_cache()},
          layouts: [map()],
          spacer: MessageView.widget_item() | nil,
          items: [MessageView.widget_item()],
          item_ids: [String.t() | nil],
          visible_items: [MessageView.widget_item()],
          visible_offset: non_neg_integer(),
          content_height: non_neg_integer(),
          scroll_offset: non_neg_integer(),
          follow?: boolean(),
          new_output?: boolean(),
          anchor: anchor() | nil,
          welcome_model: String.t() | nil
        }

  defstruct native: nil,
            text_selection: nil,
            selected_entry: nil,
            width: 1,
            viewport_height: 0,
            rect: %Rect{},
            sections: %{},
            layouts: [],
            spacer: nil,
            items: [],
            item_ids: [],
            visible_items: [],
            visible_offset: 0,
            content_height: 0,
            scroll_offset: 0,
            follow?: true,
            new_output?: false,
            anchor: nil,
            welcome_model: nil

  @doc "Creates an empty conversation model for the transcript rect."
  @spec new(Rect.t()) :: t()
  def new(%Rect{} = rect) do
    width = max(rect.width, 1)
    {native, 0} = NativeConversation.assemble_sections([[], [], [], []], width)

    %__MODULE__{
      native: native,
      width: max(rect.width, 1),
      viewport_height: max(rect.height, 0),
      rect: rect,
      sections: empty_sections(),
      spacer: NativeConversation.spacer(width)
    }
  end

  @doc "Rebuilds dimensions while retaining cached rows and reading position."
  @spec resize(t(), Rect.t()) :: t()
  def resize(%__MODULE__{} = conversation, %Rect{} = rect) do
    anchor = reading_anchor(conversation)
    width = max(rect.width, 1)

    {sections, layouts, spacer, items, item_ids, native, content_height} =
      if width == conversation.width do
        {conversation.sections, conversation.layouts, conversation.spacer, conversation.items,
         conversation.item_ids, conversation.native, conversation.content_height}
      else
        sections =
          Map.new(conversation.sections, fn {section, cache} ->
            {section, cache_entries(cache.entries, width, cache)}
          end)

        spacer = NativeConversation.spacer(width)
        layouts = build_layouts(sections, [], spacer, width, conversation.welcome_model)
        {items, item_ids} = flatten_layouts(layouts)

        {native, height} =
          NativeConversation.assemble_sections(Enum.map(layouts, & &1.items), width)

        {sections, layouts, spacer, items, item_ids, native, height}
      end

    resized = %{
      conversation
      | width: width,
        rect: rect,
        viewport_height: max(rect.height, 0),
        native: native,
        selected_entry: conversation.selected_entry,
        sections: sections,
        layouts: layouts,
        spacer: spacer,
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
          anchor_offset(resized, anchor) ||
            min(conversation.scroll_offset, max_offset)

        true ->
          min(conversation.scroll_offset, max_offset)
      end

    resized = %{
      resized
      | text_selection: Tackle.CLI.TUI.TextSelection.reconcile(conversation, resized)
    }

    resized
    |> Map.merge(%{scroll_offset: scroll_offset, follow?: conversation.follow?})
    |> put_anchor()
    |> put_visible()
  end

  @doc "Refreshes selected sections, retaining unchanged cells and layout snapshots."
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

    welcome_model = model_ref(state)

    layouts =
      build_layouts(
        section_cache,
        conversation.layouts,
        conversation.spacer,
        conversation.width,
        welcome_model
      )

    layout_changed? = layouts != conversation.layouts
    layouts = if layout_changed?, do: layouts, else: conversation.layouts

    {items, item_ids, native, content_height} =
      if layout_changed? do
        {items, item_ids} = flatten_layouts(layouts)

        {native, height} =
          layouts
          |> Enum.with_index()
          |> Enum.reduce({conversation.native, conversation.content_height}, fn {layout, index},
                                                                                acc ->
            if layout == Enum.at(conversation.layouts, index) do
              acc
            else
              {native, _height} = acc
              NativeConversation.replace_section(native, index, layout.items)
            end
          end)

        {items, item_ids, native, height}
      else
        {conversation.items, conversation.item_ids, conversation.native,
         conversation.content_height}
      end

    max_offset = max(content_height - conversation.viewport_height, 0)

    anchored_offset =
      if layout_changed?,
        do: anchor_offset(%{conversation | layouts: layouts}, preserved_anchor),
        else: conversation.scroll_offset

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
        layouts: layouts,
        items: items,
        item_ids: item_ids,
        content_height: content_height,
        scroll_offset: scroll_offset,
        follow?: follow?,
        new_output?: new_output?,
        anchor: nil,
        welcome_model: welcome_model
    }

    refreshed = %{
      refreshed
      | text_selection: Tackle.CLI.TUI.TextSelection.reconcile(conversation, refreshed)
    }

    if layout_changed? do
      refreshed |> put_anchor() |> put_visible()
    else
      %{refreshed | anchor: preserved_anchor}
    end
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
    case entry_span(conversation, id) do
      nil ->
        conversation

      {offset, _height} ->
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
  def affordance(%__MODULE__{new_output?: true}), do: "↓ New output · Alt+> latest"
  def affordance(%__MODULE__{follow?: false}), do: "↑ Reading back · Alt+> latest"
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
    Map.new(@sections, &{&1, %{entries: [], groups: [], item_ids: [], cells: %{}, width: nil}})
  end

  @doc "Returns the native widget for this immutable transcript snapshot."
  @spec widget(t()) :: NativeConversation.t()
  def widget(%__MODULE__{} = conversation) do
    selected =
      if conversation.selected_entry do
        {indices, _base} =
          Enum.map_reduce(conversation.layouts, 0, fn layout, base ->
            indices =
              case Map.get(layout.spans, conversation.selected_entry) do
                %{indices: indices} ->
                  indices |> Enum.reverse() |> Enum.map(&(&1 + base))

                nil ->
                  []
              end

            {indices, base + tuple_size(layout.rows)}
          end)

        List.flatten(indices)
      else
        []
      end

    %NativeConversation{
      state: conversation.native,
      scroll_offset: conversation.scroll_offset,
      selected: selected,
      text_selection: Tackle.CLI.TUI.TextSelection.range(conversation.text_selection)
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
    if previous.width == width and previous.entries == entries do
      previous
    else
      cached =
        if previous.width == width,
          do:
            Map.new(Enum.zip(previous.entries, previous.groups), fn {entry, group} ->
              {entry.id, {entry, group}}
            end),
          else: %{}

      {groups, cells} =
        Enum.map_reduce(entries, %{}, fn entry, cells ->
          previous_cells = Map.get(Map.get(previous, :cells, %{}), entry.id, %{})

          {group, cell_cache} =
            case Map.get(cached, entry.id) do
              {^entry, group} -> {group, previous_cells}
              _ -> NativeConversation.cached_cell(entry, width, previous_cells)
            end

          {group, Map.put(cells, entry.id, cell_cache)}
        end)

      item_ids =
        Enum.zip(entries, groups)
        |> Enum.map(fn {entry, items} -> List.duplicate(entry.id, length(items)) end)

      %{entries: entries, groups: groups, item_ids: item_ids, cells: cells, width: width}
    end
  end

  defp build_layouts(section_cache, previous, spacer, width, welcome_model) do
    welcome? = Enum.all?(@sections, &(section_cache[&1].groups == []))

    @sections
    |> Enum.with_index()
    |> Enum.map_reduce(false, fn {section, index}, seen? ->
      cache = Map.fetch!(section_cache, section)
      welcome = welcome? and index == 0
      key = {cache.groups, cache.item_ids, seen?, if(welcome, do: {:welcome, welcome_model})}
      old = Enum.at(previous, index)

      layout =
        if old && old.key == key do
          old
        else
          {groups, ids} =
            if welcome do
              group = NativeConversation.cell(MessageView.welcome_entry(welcome_model), width)
              {[group], [List.duplicate("welcome", length(group))]}
            else
              {cache.groups, cache.item_ids}
            end

          items = groups |> Enum.intersperse([spacer]) |> List.flatten()
          item_ids = ids |> Enum.intersperse([nil]) |> List.flatten()

          {items, item_ids} =
            if seen? and groups != [],
              do: {[spacer | items], [nil | item_ids]},
              else: {items, item_ids}

          index_layout(key, items, item_ids)
        end

      {layout, seen? or layout.items != []}
    end)
    |> elem(0)
  end

  defp index_layout(key, items, ids) do
    {rows, spans, height} =
      Enum.zip(items, ids)
      |> Enum.with_index()
      |> Enum.reduce({[], %{}, 0}, fn {{{cell, height}, id}, index}, {rows, spans, top} ->
        spans =
          if id do
            Map.update(spans, id, %{top: top, height: height, indices: [index]}, fn span ->
              contiguous? = hd(span.indices) == index - 1 and span.top + span.height == top

              %{
                span
                | indices: [index | span.indices],
                  height: if(contiguous?, do: span.height + height, else: span.height)
              }
            end)
          else
            spans
          end

        {[{top, {cell, height}, id} | rows], spans, top + height}
      end)

    %{
      key: key,
      items: items,
      item_ids: ids,
      rows: rows |> Enum.reverse() |> List.to_tuple(),
      spans: spans,
      height: height
    }
  end

  # Preserve the flat compatibility fields; expensive native placement and row
  # indexes are retained per section instead of being rebuilt from this list.
  defp flatten_layouts(layouts) do
    {Enum.flat_map(layouts, & &1.items), Enum.flat_map(layouts, & &1.item_ids)}
  end

  defp model_ref(%{agent_state: %{llm: %{ref: ref}}}) when is_binary(ref), do: ref
  defp model_ref(%{agent_state: %{model: model}}) when is_binary(model), do: model
  defp model_ref(_state), do: nil

  @doc false
  @spec same_prefix?(t(), t(), non_neg_integer()) :: boolean()
  def same_prefix?(%__MODULE__{} = old, %__MODULE__{} = new, last_row),
    do: same_prefix_layouts?(old.layouts, new.layouts, last_row)

  defp same_prefix_layouts?([], [], _row), do: true

  defp same_prefix_layouts?([old | olds], [new | news], row) do
    cond do
      old == new ->
        row < old.height or same_prefix_layouts?(olds, news, row - old.height)

      true ->
        prefix_rows(old.rows, row) == prefix_rows(new.rows, row) and
          (row < old.height or same_prefix_layouts?(olds, news, row - old.height))
    end
  end

  defp same_prefix_layouts?(_, _, _row), do: false

  defp prefix_rows(rows, row) do
    last = row_index(rows, row)

    if tuple_size(rows) == 0 do
      []
    else
      for index <- 0..last do
        {top, {cell, height}, id} = elem(rows, index)
        {top, height, if(id, do: cell, else: :spacer)}
      end
    end
  end

  defp put_visible(%__MODULE__{} = conversation) do
    {visible, offset} =
      visible(conversation.layouts, conversation.scroll_offset, conversation.viewport_height)

    %{conversation | visible_items: visible, visible_offset: offset}
  end

  # Skip whole retained sections, then binary-search the first visible cell.
  defp visible([], _offset, _height), do: {[], 0}

  defp visible([layout | rest], offset, height) when offset >= layout.height,
    do: visible(rest, offset - layout.height, height)

  defp visible([layout | rest], offset, height) do
    index = row_index(layout.rows, offset)
    {top, _item, _id} = elem(layout.rows, index)
    within = offset - top
    {items, remaining} = take_rows(layout.rows, index, height + within, [])
    more = if remaining > 0, do: elem(visible(rest, 0, remaining), 0), else: []
    {items ++ more, within}
  end

  defp take_rows(rows, index, remaining, acc) when index >= tuple_size(rows) or remaining <= 0,
    do: {Enum.reverse(acc), remaining}

  defp take_rows(rows, index, remaining, acc) do
    {_top, {_cell, height} = item, _id} = elem(rows, index)
    take_rows(rows, index + 1, remaining - height, [item | acc])
  end

  defp row_index(rows, offset), do: row_index(rows, offset, 0, tuple_size(rows))
  defp row_index(_rows, _offset, low, high) when low >= high, do: max(low - 1, 0)

  defp row_index(rows, offset, low, high) do
    mid = div(low + high, 2)
    {top, _, _} = elem(rows, mid)

    if top <= offset,
      do: row_index(rows, offset, mid + 1, high),
      else: row_index(rows, offset, low, mid)
  end

  defp put_anchor(%__MODULE__{follow?: true} = conversation), do: %{conversation | anchor: nil}
  defp put_anchor(conversation), do: %{conversation | anchor: capture_anchor(conversation)}
  defp reading_anchor(%__MODULE__{follow?: true}), do: nil
  defp reading_anchor(conversation), do: conversation.anchor || capture_anchor(conversation)

  defp capture_anchor(conversation) do
    case locate(conversation.layouts, conversation.scroll_offset, 0) do
      nil ->
        nil

      {layout, index, _base} ->
        {_top, _item, id} = elem(layout.rows, index)
        id = id || nearest_id(conversation.layouts, layout, index)

        case entry_span(conversation, id) do
          {start, _height} -> %{id: id, offset: max(conversation.scroll_offset - start, 0)}
          nil -> nil
        end
    end
  end

  defp locate([], _offset, _base), do: nil

  defp locate([layout | rest], offset, base) when offset >= layout.height,
    do: locate(rest, offset - layout.height, base + layout.height)

  defp locate([layout | _], offset, base), do: {layout, row_index(layout.rows, offset), base}

  # Spacer rows anchor to the next entry, or the preceding entry at the end.
  defp nearest_id(layouts, current, index) do
    position = Enum.find_index(layouts, &(&1 == current))
    forward = next_id(current.rows, index + 1, 1)

    forward ||
      layouts |> Enum.drop(position + 1) |> Enum.find_value(&next_id(&1.rows, 0, 1)) ||
      next_id(current.rows, index - 1, -1) ||
      layouts
      |> Enum.take(position)
      |> Enum.reverse()
      |> Enum.find_value(&next_id(&1.rows, tuple_size(&1.rows) - 1, -1))
  end

  defp next_id(rows, index, _step) when index < 0 or index >= tuple_size(rows), do: nil

  defp next_id(rows, index, step) do
    {_, _, id} = elem(rows, index)
    id || next_id(rows, index + step, step)
  end

  defp anchor_offset(_conversation, nil), do: nil

  defp anchor_offset(conversation, %{id: id, offset: offset}) do
    case entry_span(conversation, id) do
      {top, height} -> top + min(offset, max(height - 1, 0))
      nil -> nil
    end
  end

  defp entry_span(conversation, id) do
    Enum.reduce_while(conversation.layouts, 0, fn layout, base ->
      case Map.get(layout.spans, id) do
        %{top: top, height: height} -> {:halt, {base + top, height}}
        nil -> {:cont, base + layout.height}
      end
    end)
    |> case do
      {top, height} -> {top, height}
      _ -> nil
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

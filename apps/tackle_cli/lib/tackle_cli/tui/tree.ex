defmodule Tackle.CLI.TUI.Tree do
  @moduledoc """
  The conversation-tree screen: `/tree`.

  A full-screen, search-first browser over the session's settled history, laid
  out like the `/resume` screen and drawn like a Git graph. Every user prompt
  is a `●` node on a vertical rail; the reply (and, in the all-entries view, the
  tool steps) that follow it hang beneath the prompt as body lines. Forks
  branch off with `├─●` / `└─●`, so even a linear history reads as a tree, and
  the active path is highlighted while other branches are dimmed.

  Tab cycles three views:

    * `:default` — user messages, assistant replies, and compaction checkpoints.
      A reply's tool calls are folded into a short summary on its row.
    * `:user` — user messages only.
    * `:all` — every entry, with tool rows showing their main argument.

  Hidden entries keep the structure intact: every visible row hangs off its
  nearest visible ancestor. The current position is always visible.

  The screen is idle-only and knows the safety rule: an entry whose tool batch
  is incomplete is never a navigation target. The filtered views omit such
  entries; the all-entries view shows them dimmed as *inspect only*, and the
  cursor skips them.

  Selecting a user message moves to its parent and offers that message back to
  the composer as a draft, so submitting the edit creates a sibling branch.
  Selecting any other entry moves to it; selecting the start row returns to the
  empty conversation before the first message. Navigation is asynchronous, so
  the shell stays responsive; the runtime validates, persists, and then reports
  the committed destination, which this module installs together with the
  rebuilt transcript.

  Navigation does not undo workspace changes, and it never silently overwrites a
  draft the user is writing: an untouched composer receives the selected user
  text, while a non-empty draft is kept and the notice says so.
  """

  alias ExRatatui.Command
  alias Tackle.CLI.TUI.{Compaction, Picker, State, Util, Viewport}
  alias Tackle.CLI.Widgets.{Input, TreeScreen}
  alias Tackle.Lib.Message
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Tree, as: ConversationTree
  alias Tackle.Lib.Tree.Navigator.Outcome

  @root_id :conversation_root
  @unsafe_id :unsafe_entry
  @views [:default, :user, :all]
  @preview_width 200
  @argument_width 60
  @argument_keys ~w(path file_path command pattern query url)a

  @typedoc "Which entries the screen shows."
  @type view :: :default | :user | :all

  @typedoc """
  One screen row.

  Besides the `Picker.item()` fields, a row carries its graph `:prefix` (rails
  and connectors), a node `:glyph` (nil for body lines under a prompt), its
  `:kind`, its `:entry_id`, and whether it is on the active path, the current
  position, or an unsafe (inspect-only) entry.
  """
  @type row :: %{
          required(:id) => term(),
          required(:entry_id) => String.t() | nil,
          required(:kind) => :root | :user | :reply | :assistant | :tool | :compaction | :entry,
          required(:primary) => String.t(),
          required(:secondary) => String.t() | nil,
          required(:search) => String.t(),
          required(:prefix) => String.t(),
          required(:glyph) => String.t() | nil,
          required(:active?) => boolean(),
          required(:current?) => boolean(),
          required(:unsafe?) => boolean(),
          optional(:marker) => String.t() | nil
        }

  @doc """
  Opens the conversation-tree screen when the shell is idle.

  Reports a notice instead when a turn is active, another operation is pending,
  or the session has no tree.
  """
  @spec open(State.t()) :: {:noreply, State.t()}
  def open(%State{active_turn: turn} = state) when not is_nil(turn) do
    {:noreply, %{state | notice: "Tree browsing is available when idle"}}
  end

  def open(%State{pending_operation: operation} = state) when not is_nil(operation) do
    {:noreply, %{state | notice: "Wait for the current operation to finish"}}
  end

  def open(%State{agent_state: %{tree: nil}} = state) do
    {:noreply, %{state | notice: "This session has no conversation tree"}}
  end

  def open(%State{} = state) do
    tree = state.agent_state.tree

    if ConversationTree.empty?(tree) do
      {:noreply, %{state | notice: "The conversation tree is empty"}}
    else
      picker =
        tree
        |> items(:default)
        |> Picker.new()
        |> select_entry(tree, ConversationTree.active_id(tree))

      overlay = %{picker: picker, view: :default, scroll_top: 0}
      {:noreply, scroll(%{state | overlay: {:tree, overlay}})}
    end
  end

  @doc "Handles one resolved tree-screen intent."
  @spec handle(atom() | tuple(), State.t()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def handle(intent, %State{} = state), do: dispatch(intent, state)

  @doc "Applies a bracketed paste to the search query."
  @spec paste(State.t(), String.t()) :: State.t()
  def paste(%State{overlay: {:tree, %{picker: picker}}} = state, content) do
    requery(state, picker.query <> String.replace(content, ~r/\s+/u, " "))
  end

  @doc "Keeps the selection visible after the terminal is resized."
  @spec resize(State.t()) :: State.t()
  def resize(%State{overlay: {:tree, _tree}} = state), do: scroll(state)

  @doc """
  Builds the rows for one view of a tree, in graph order.

  The first row is the synthetic start of the conversation. The active branch
  is listed first at every fork.
  """
  @spec items(ConversationTree.t(), view()) :: [row()]
  def items(%ConversationTree{} = tree, view \\ :default) when view in @views do
    active = ConversationTree.active_id(tree)

    context = %{
      tree: tree,
      view: view,
      active: active,
      active_path: tree |> ConversationTree.active_path() |> MapSet.new(& &1.id),
      resumable: ConversationTree.resumable_ids(tree),
      calls: tool_calls_by_id(tree)
    }

    forest = visible_forest(context)
    root = %{head: :root, body: [], children: children(context, forest, nil)}
    layout(context, forest, root, [], nil)
  end

  @doc "Builds the full-screen widget for the open tree screen."
  @spec popup(State.t()) :: TreeScreen.t()
  def popup(%State{overlay: {:tree, %{picker: picker, view: view, scroll_top: top}}}) do
    rows = filtered(picker)

    %TreeScreen{
      rows: rows,
      selected: Util.clamp(picker.selected, 0, max(length(rows) - 1, 0)),
      scroll_top: top,
      query: picker.query,
      view: view
    }
  end

  # -- visible structure -----------------------------------------------------

  # Maps each visible parent id (nil for the top level) to its visible children
  # in tree order. A child is `{entry, hidden, resumable?}`, where `hidden`
  # lists the entries between it and its visible parent, oldest first.
  defp visible_forest(context) do
    context.tree
    |> ConversationTree.roots()
    |> Enum.reduce(%{}, &collect(context, &1, nil, [], &2))
    |> Map.new(fn {parent, children} -> {parent, Enum.reverse(children)} end)
  end

  defp collect(context, entry, parent, hidden, forest) do
    resumable? = MapSet.member?(context.resumable, entry.id)

    {parent, hidden, forest} =
      if visible?(context, entry, resumable?) do
        node = {entry, Enum.reverse(hidden), resumable?}
        {entry.id, [], Map.update(forest, parent, [node], &[node | &1])}
      else
        {parent, [entry | hidden], forest}
      end

    context.tree
    |> ConversationTree.children(entry.id)
    |> Enum.reduce(forest, &collect(context, &1, parent, hidden, &2))
  end

  defp visible?(%{active: id}, %{id: id}, _resumable?), do: true
  defp visible?(%{view: :all}, _entry, _resumable?), do: true
  defp visible?(_context, _entry, false), do: false
  defp visible?(%{view: :user}, entry, true), do: user_message?(entry)

  defp visible?(%{view: :default}, entry, true),
    do: user_message?(entry) or reply?(entry) or entry.kind == :compaction

  defp user_message?(%{kind: :message, message: %Message{role: :user}}), do: true
  defp user_message?(_entry), do: false

  defp reply?(%{kind: :message, message: %Message{role: :assistant, content: content}}),
    do: is_binary(content) and String.trim(content) != ""

  defp reply?(_entry), do: false

  # -- graph layout ----------------------------------------------------------

  # Visible children of `parent_id`, the branch holding the current position
  # first, each grouped into a unit.
  defp children(context, forest, parent_id) do
    forest
    |> Map.get(parent_id, [])
    |> Enum.sort_by(fn {entry, _hidden, _resumable?} ->
      if MapSet.member?(context.active_path, entry.id), do: 0, else: 1
    end)
    |> Enum.map(&unit(context, forest, &1))
  end

  # A unit is one graph node: a head entry plus the straight run of non-user
  # entries after it (the reply, or the tool steps and reply), drawn as body
  # lines. It ends at a fork or at the next user message.
  defp unit(context, forest, {entry, _hidden, _resumable?} = head) do
    {body, last_id} = absorb(forest, entry.id, [])
    %{head: head, body: body, children: children(context, forest, last_id)}
  end

  defp absorb(forest, id, body) do
    case Map.get(forest, id, []) do
      [{entry, _hidden, _resumable?} = node] ->
        if user_message?(entry) or entry.kind == :compaction,
          do: {Enum.reverse(body), id},
          else: absorb(forest, entry.id, [node | body])

      _none_or_fork ->
        {Enum.reverse(body), id}
    end
  end

  # `rails` holds one flag per indentation level: whether a vertical rail runs
  # past this unit's rows at that level. `connector` is `:mid` or `:last` when
  # the unit is one branch of a fork, which draws `├─` or `└─` on its head row.
  defp layout(context, forest, unit, rails, connector) do
    head_prefix = head_prefix(rails, connector)
    body_prefix = rail_cells(rails) <> if(unit.children == [], do: "  ", else: "│ ")

    rows =
      [row(context, unit.head, head_prefix, true)] ++
        Enum.map(unit.body, &row(context, &1, body_prefix, false))

    child_rows =
      case unit.children do
        [] ->
          []

        [child] ->
          layout(context, forest, child, rails, nil)

        branches ->
          last = length(branches) - 1

          branches
          |> Enum.with_index()
          |> Enum.flat_map(fn {child, index} ->
            connector = if index == last, do: :last, else: :mid
            layout(context, forest, child, rails ++ [index != last], connector)
          end)
      end

    rows ++ child_rows
  end

  defp head_prefix(rails, nil), do: rail_cells(rails)

  defp head_prefix(rails, connector),
    do: rail_cells(Enum.drop(rails, -1)) <> if(connector == :mid, do: "├─", else: "└─")

  defp rail_cells(rails), do: Enum.map_join(rails, &if(&1, do: "│ ", else: "  "))

  defp row(context, :root, prefix, true) do
    current? = is_nil(context.active)

    %{
      id: @root_id,
      entry_id: nil,
      kind: :root,
      primary: "Start of conversation",
      secondary: if(current?, do: "current"),
      search: "start of conversation",
      prefix: prefix,
      glyph: "○",
      marker: nil,
      active?: true,
      current?: current?,
      unsafe?: false
    }
  end

  defp row(context, {entry, hidden, resumable?}, prefix, head?) do
    current? = entry.id == context.active

    %{
      id: target(entry, resumable?),
      entry_id: entry.id,
      kind: kind(entry),
      primary: label(entry, context.calls),
      secondary: secondary(context.view, entry, hidden, resumable?, current?),
      search: search_text(entry, context.calls),
      prefix: prefix,
      glyph: if(head?, do: glyph(entry)),
      marker: nil,
      active?: MapSet.member?(context.active_path, entry.id),
      current?: current?,
      unsafe?: not resumable?
    }
  end

  defp kind(%{kind: :compaction}), do: :compaction
  defp kind(%{kind: :message, message: %Message{role: :user}}), do: :user
  defp kind(%{kind: :message, message: %Message{role: :tool}}), do: :tool
  defp kind(%{kind: :message} = entry), do: if(reply?(entry), do: :reply, else: :assistant)
  defp kind(_entry), do: :entry

  defp glyph(%{kind: :compaction}), do: "≡"
  defp glyph(entry), do: if(user_message?(entry), do: "●", else: "◇")

  # -- selection -------------------------------------------------------------

  defp filtered(%Picker{query: "", items: items}), do: items

  defp filtered(%Picker{items: items, query: query}) do
    matches = items |> Picker.filter(query) |> MapSet.new()
    Enum.filter(items, &MapSet.member?(matches, &1))
  end

  defp selected_item(%Picker{} = picker) do
    picker |> filtered() |> Enum.at(picker.selected)
  end

  # Selects the row for `entry_id`, or the row of its nearest visible ancestor
  # when the current view hides it, falling back to the start row.
  defp select_entry(%Picker{} = picker, tree, entry_id) do
    rows = filtered(picker)

    candidates =
      tree
      |> ConversationTree.ancestry(entry_id)
      |> Enum.reverse()
      |> Enum.map(& &1.id)

    index =
      Enum.find_value(candidates, fn id ->
        Enum.find_index(rows, &(&1.entry_id == id and not &1.unsafe?))
      end) || Enum.find_index(rows, &(&1.id == @root_id)) || 0

    settle(%{picker | selected: index})
  end

  # After a query change, selects the best-ranked selectable match; the rows
  # themselves stay in graph order so the structure remains readable.
  defp select_best(%Picker{query: query} = picker) do
    best = picker.items |> Picker.filter(query) |> Enum.find(&(not &1.unsafe?))
    index = if best, do: Enum.find_index(filtered(picker), &(&1 == best)), else: 0
    settle(%{picker | selected: index})
  end

  # Moves by `delta` rows, skipping inspect-only rows in the direction of travel.
  # The selection stays put when no selectable row lies in that direction.
  defp move(%Picker{} = picker, delta) do
    rows = picker |> filtered() |> List.to_tuple()
    direction = if delta < 0, do: -1, else: 1
    target = Util.clamp(picker.selected + delta, 0, max(tuple_size(rows) - 1, 0))

    case next_selectable(rows, target, direction) || next_selectable(rows, target, -direction) do
      nil -> picker
      index -> %{picker | selected: index}
    end
  end

  # Keeps the cursor off inspect-only rows after the row list changes.
  defp settle(%Picker{} = picker) do
    rows = picker |> filtered() |> List.to_tuple()
    selected = Util.clamp(picker.selected, 0, max(tuple_size(rows) - 1, 0))

    index =
      next_selectable(rows, selected, 1) || next_selectable(rows, selected, -1) || selected

    %{picker | selected: index}
  end

  defp next_selectable(rows, index, _direction) when index < 0 or index >= tuple_size(rows),
    do: nil

  defp next_selectable(rows, index, direction) do
    if elem(rows, index).unsafe?,
      do: next_selectable(rows, index + direction, direction),
      else: index
  end

  # Rebuilds the rows for another view, keeping the selection on the same
  # entry, or on its nearest visible ancestor.
  defp rebuild(state, view) do
    {:tree, %{picker: picker} = overlay} = state.overlay
    tree = state.agent_state.tree

    picker =
      tree
      |> items(view)
      |> Picker.new(picker.query)
      |> select_entry(tree, selected_entry_id(picker, tree))

    scroll(%{state | overlay: {:tree, %{overlay | picker: picker, view: view}}})
  end

  # Applies a new search query over the same rows. A non-empty query selects
  # its best match; clearing it returns to the entry that was selected.
  defp requery(state, query) do
    {:tree, %{picker: picker} = overlay} = state.overlay
    tree = state.agent_state.tree
    entry_id = selected_entry_id(picker, tree)
    picker = Picker.new(picker.items, query)

    picker =
      if query == "", do: select_entry(picker, tree, entry_id), else: select_best(picker)

    scroll(%{state | overlay: {:tree, %{overlay | picker: picker}}})
  end

  defp selected_entry_id(picker, tree) do
    case selected_item(picker) do
      nil -> ConversationTree.active_id(tree)
      item -> item.entry_id
    end
  end

  defp cycle_view(state, step) do
    {:tree, %{view: view}} = state.overlay
    index = Enum.find_index(@views, &(&1 == view))

    rebuild(state, Enum.at(@views, rem(index + step + length(@views), length(@views))))
  end

  defp page(state), do: max(TreeScreen.list_height(state.size) - 1, 1)

  # Keeps the selected row inside the visible list window.
  defp scroll(%State{overlay: {:tree, %{picker: picker} = overlay}} = state) do
    count = length(filtered(picker))
    height = TreeScreen.list_height(state.size)
    top = TreeScreen.scroll_top(overlay.scroll_top, picker.selected, count, height)
    %{state | overlay: {:tree, %{overlay | scroll_top: top}}}
  end

  defp update_picker(%State{overlay: {:tree, %{picker: picker} = overlay}} = state, fun),
    do: scroll(%{state | overlay: {:tree, %{overlay | picker: fun.(picker)}}})

  # -- row text --------------------------------------------------------------

  # An incomplete tool batch is inspectable but not selectable: navigating there
  # would replay a tool or fabricate a result, which the runtime must never do.
  defp target(_entry, false), do: @unsafe_id
  defp target(%{kind: :message, message: %Message{role: :user, id: id}}, true), do: {:edit, id}
  defp target(%{id: id}, true), do: {:entry, id}

  defp label(%{kind: :message, message: %Message{role: :user} = message}, _calls),
    do: preview(message.content)

  defp label(%{kind: :message, message: %Message{role: :assistant} = message}, _calls) do
    cond do
      is_binary(message.content) and String.trim(message.content) != "" ->
        preview(message.content)

      message.tool_calls == [] ->
        "(reasoning)"

      true ->
        "→ " <> Enum.map_join(message.tool_calls, ", ", & &1.name)
    end
  end

  defp label(%{kind: :message, message: %Message{role: :tool} = message}, calls),
    do: tool_summary(message, calls)

  defp label(%{kind: :compaction, compaction: compaction}, _calls),
    do: "context compacted · #{length(compaction.shadowed_message_ids)} messages"

  defp label(_entry, _calls), do: "entry"

  defp secondary(view, entry, hidden, resumable?, current?) do
    [
      if(not resumable?, do: "inspect only"),
      if(view == :default and reply?(entry), do: tools_used(hidden)),
      if(current?, do: "current")
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  # Summarizes the tool calls folded away before a reply: "3 tools: read, edit".
  defp tools_used(hidden) do
    names =
      Enum.flat_map(hidden, fn
        %{kind: :message, message: %Message{role: :assistant, tool_calls: [_ | _] = calls}} ->
          Enum.map(calls, & &1.name)

        _entry ->
          []
      end)

    case names do
      [] ->
        nil

      names ->
        count = length(names)
        unique = Enum.uniq(names)
        shown = Enum.take(unique, 3)
        more = if length(unique) > 3, do: " +#{length(unique) - 3}", else: ""
        noun = if count == 1, do: "tool", else: "tools"
        "#{count} #{noun}: #{Enum.join(shown, ", ")}#{more}"
    end
  end

  defp tool_summary(%Message{} = message, calls) do
    name = message.tool_name || "tool"

    case calls |> Map.get(message.tool_call_id) |> call_argument() do
      nil -> name
      argument -> name <> " " <> argument
    end
  end

  defp tool_calls_by_id(tree) do
    tree
    |> ConversationTree.enumerate()
    |> Enum.flat_map(fn
      %{kind: :message, message: %Message{tool_calls: [_ | _] = calls}} -> calls
      _entry -> []
    end)
    |> Enum.flat_map(fn
      %Call{id: id} = call when is_binary(id) -> [{id, call}]
      %Call{} -> []
    end)
    |> Map.new()
  end

  defp call_argument(nil), do: nil

  defp call_argument(%Call{arguments: arguments}) do
    Enum.find_value(@argument_keys, fn key ->
      case Map.get(arguments, key) || Map.get(arguments, Atom.to_string(key)) do
        value when is_binary(value) and value != "" -> format_argument(key, value)
        _other -> nil
      end
    end)
  end

  defp format_argument(key, value) when key in [:path, :file_path],
    do: value |> Path.relative_to_cwd() |> Util.truncate(@argument_width)

  defp format_argument(_key, value), do: value |> one_line() |> Util.truncate(@argument_width)

  defp search_text(%{kind: :message, message: %Message{role: :tool} = message}, calls) do
    Enum.join(Enum.reject([tool_summary(message, calls), message.content], &is_nil/1), " ")
  end

  defp search_text(%{kind: :message, message: %Message{} = message}, _calls) do
    Enum.join(Enum.reject([message.content, message.thinking, message.tool_name], &is_nil/1), " ")
  end

  defp search_text(%{kind: :compaction, compaction: compaction}, _calls) do
    Tackle.Lib.Compaction.Checkpoint.body(compaction.summary_message) || "context compacted"
  end

  defp search_text(_entry, _calls), do: ""

  defp preview(nil), do: ""
  defp preview(text), do: text |> one_line() |> Util.truncate(@preview_width)

  defp one_line(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  # -- intents ---------------------------------------------------------------

  defp dispatch(:close, state), do: {:noreply, %{state | overlay: nil}}

  # Esc clears an active search first, like the resume screen, then closes.
  defp dispatch(:cancel, %State{overlay: {:tree, %{picker: %{query: ""}}}} = state),
    do: dispatch(:close, state)

  defp dispatch(:cancel, state), do: {:noreply, requery(state, "")}

  defp dispatch(:previous, state), do: {:noreply, update_picker(state, &move(&1, -1))}
  defp dispatch(:next, state), do: {:noreply, update_picker(state, &move(&1, 1))}

  defp dispatch(:page_up, state),
    do: {:noreply, update_picker(state, &move(&1, -page(state)))}

  defp dispatch(:page_down, state),
    do: {:noreply, update_picker(state, &move(&1, page(state)))}

  defp dispatch(:next_view, state), do: {:noreply, cycle_view(state, 1)}
  defp dispatch(:previous_view, state), do: {:noreply, cycle_view(state, -1)}

  defp dispatch(:backspace, %State{overlay: {:tree, %{picker: picker}}} = state),
    do: {:noreply, requery(state, Picker.backspace(picker).query)}

  defp dispatch({:insert, text}, %State{overlay: {:tree, %{picker: picker}}} = state),
    do: {:noreply, requery(state, Picker.insert(picker, text).query)}

  defp dispatch(:accept, state) do
    {:tree, %{picker: picker}} = state.overlay

    case selected_item(picker) do
      nil ->
        {:noreply, state, render?: false}

      %{id: @unsafe_id} ->
        {:noreply, %{state | notice: "Unsafe continuation point · inspect the history instead"}}

      %{id: @root_id} ->
        navigate(state, nil)

      %{id: {:edit, id}} ->
        navigate(state, {:edit, id})

      %{id: {:entry, id}} ->
        navigate(state, {:entry, id})
    end
  end

  defp dispatch(:ignore, state), do: {:noreply, state, render?: false}

  defp navigate(state, target) do
    ref = make_ref()
    agent_ref = state.agent_ref

    command =
      Command.async(
        fn -> Tackle.navigate(agent_ref, target) end,
        &{:tui_operation_result, ref, :navigate, &1}
      )

    state = %{
      state
      | pending_operation: %{
          ref: ref,
          kind: :navigate,
          started_at_ms: System.monotonic_time(:millisecond)
        },
        overlay: nil,
        activity: "navigating",
        error: nil,
        outcome: nil,
        notice: nil
    }

    {:noreply, state, commands: [command]}
  end

  @doc """
  Installs a committed navigation outcome into the shell.

  Rebuilds the transcript from the destination snapshot, restores the branch's
  checkpoint card, and fills an untouched composer with a selected user message.
  A non-empty draft is preserved and the notice explains why.
  """
  @spec apply_outcome(State.t(), Outcome.t()) :: State.t()
  def apply_outcome(%State{} = state, %Outcome{} = outcome) do
    state = %{state | notice: notice(outcome)}
    state = Compaction.restore(state)

    case outcome.draft do
      %Message{content: content} when is_binary(content) and content != "" ->
        if state.draft_empty? do
          :ok = Input.set_value(state.input, content)
          state |> Viewport.update_draft() |> Viewport.relayout()
        else
          %{state | notice: notice(outcome) <> " · draft kept"}
        end

      _other ->
        state
    end
  end

  defp notice(%Outcome{change: %{mode: :edit}, draft: %Message{content: content}})
       when is_binary(content),
       do: "Editing an earlier message · submit to branch · workspace is unchanged"

  defp notice(%Outcome{change: %{to_id: nil}}),
    do: "Moved before the first message · workspace is unchanged"

  defp notice(_outcome), do: "Moved to an earlier position · workspace is unchanged"
end

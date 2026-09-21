defmodule Tackle.CLI.TUI.Tree do
  @moduledoc """
  The conversation-tree picker: `/tree`.

  A tree browser is a search-first `Picker` over the session's settled history,
  rendered with branch indentation and an active-position marker. Independent
  root histories begin at the left edge (the synthetic start row adds no fork);
  real forks within a history retain their connectors. Selecting a
  user message moves to its parent and offers that message back to the composer
  as a draft, so submitting the edit creates a sibling branch. Selecting any
  other entry moves to it; selecting the start row returns to the empty
  conversation before the first message.

  The picker is idle-only and knows the safety rule: an entry whose tool batch is
  incomplete is shown as *inspect only* and cannot be selected for execution.
  Navigation is asynchronous, so the shell stays responsive; the runtime
  validates, persists, and then reports the committed destination, which this
  module installs together with the rebuilt transcript.

  Navigation does not undo workspace changes, and it never silently overwrites a
  draft the user is writing: an untouched composer receives the selected user
  text, while a non-empty draft is kept and the notice says so.
  """

  alias ExRatatui.Command
  alias Tackle.CLI.TUI.{Compaction, Picker, State, Util, Viewport}
  alias Tackle.CLI.Widgets.{Input, TreePopup}
  alias Tackle.Lib.Message
  alias Tackle.Lib.Tree, as: ConversationTree

  @root_id :conversation_root
  @unsafe_id :unsafe_entry

  @doc """
  Opens the conversation-tree picker when the shell is idle.

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
    if ConversationTree.empty?(state.agent_state.tree) do
      {:noreply, %{state | notice: "The conversation tree is empty"}}
    else
      picker =
        state.agent_state.tree
        |> items()
        |> Picker.new()
        |> select_active()

      {:noreply, %{state | overlay: {:tree, %{picker: picker}}}}
    end
  end

  @doc "Handles one resolved tree-picker intent."
  @spec handle(atom() | tuple(), State.t()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def handle(intent, %State{} = state), do: dispatch(intent, state)

  @doc "Applies a bracketed paste to the picker query."
  @spec paste(State.t(), String.t()) :: State.t()
  def paste(%State{overlay: {:tree, %{picker: picker}}} = state, content) do
    query = picker.query <> String.replace(content, ~r/\s+/u, " ")
    %{state | overlay: {:tree, %{picker: Picker.new(picker.items, query)}}}
  end

  @doc "Builds the picker rows for a tree in branch order."
  @spec items(ConversationTree.t()) :: [Picker.item()]
  def items(%ConversationTree{} = tree) do
    active = ConversationTree.active_id(tree)
    active_path = tree |> ConversationTree.active_path() |> MapSet.new(& &1.id)

    root = %{
      id: @root_id,
      primary: "Start of conversation",
      secondary: if(is_nil(active), do: "current position", else: nil),
      marker: marker(active, nil),
      search: "start root beginning empty conversation",
      depth: 0,
      connector?: false,
      last?: true,
      ancestor_continues: [],
      active?: is_nil(active),
      unsafe?: false
    }

    roots =
      tree
      |> ConversationTree.roots()
      |> Enum.sort_by(fn entry -> if subtree_active?(tree, entry, active), do: 0, else: 1 end)

    multiple_roots? = match?([_, _ | _], roots)

    rows =
      roots
      |> Enum.with_index()
      |> Enum.flat_map(fn {entry, index} ->
        walk(
          tree,
          entry,
          if(multiple_roots?, do: 1, else: 0),
          multiple_roots?,
          index == length(roots) - 1,
          %{},
          active,
          active_path
        )
      end)

    # Multiple histories share only a synthetic root, not a conversation entry.
    # Like pi, suppress that virtual fork and shift its entire forest left.
    rows = if multiple_roots?, do: Enum.map(rows, &without_virtual_root/1), else: rows

    [root | rows]
  end

  defp without_virtual_root(item) do
    %{
      item
      | depth: item.depth - 1,
        connector?: item.connector? and item.depth > 1,
        ancestor_continues: tl(item.ancestor_continues)
    }
  end

  @doc "Renders the open tree picker with a native tree viewport."
  @spec popup(State.t()) :: TreePopup.t()
  def popup(%State{overlay: {:tree, %{picker: picker}}}) do
    items = filtered(picker)

    %TreePopup{
      nodes: Enum.map(items, &tree_node/1),
      selected: Util.clamp(picker.selected, 0, max(length(items) - 1, 0)),
      query: picker.query,
      count: length(items)
    }
  end

  defp walk(
         tree,
         entry,
         depth,
         connector?,
         last?,
         ancestors,
         active,
         active_path
       ) do
    children =
      tree
      |> ConversationTree.children(entry.id)
      |> Enum.sort_by(fn child -> if subtree_active?(tree, child, active), do: 0, else: 1 end)

    multiple_children? = match?([_, _ | _], children)

    child_depth =
      cond do
        multiple_children? -> depth + 1
        connector? and depth > 0 -> depth + 1
        true -> depth
      end

    child_ancestors =
      if connector? do
        put_gutter(ancestors, depth - 1, not last?)
      else
        ancestors
      end

    child_rows =
      children
      |> Enum.with_index()
      |> Enum.flat_map(fn {child, index} ->
        walk(
          tree,
          child,
          child_depth,
          multiple_children?,
          index == length(children) - 1,
          child_ancestors,
          active,
          active_path
        )
      end)

    [
      row(tree, entry, depth, connector?, last?, ancestors, active, active_path)
      | child_rows
    ]
  end

  defp row(tree, entry, depth, connector?, last?, ancestors, active, active_path) do
    resumable? = ConversationTree.resumable?(tree, entry.id)

    %{
      id: target(entry, resumable?),
      primary: label(entry),
      secondary: secondary(entry, resumable?),
      marker: marker(active, entry.id),
      search: search_text(entry),
      depth: depth,
      connector?: connector?,
      last?: last?,
      ancestor_continues: gutters(ancestors, depth),
      active?: MapSet.member?(active_path, entry.id),
      unsafe?: not resumable?
    }
  end

  defp tree_node(item) do
    %{
      text: display_label(item),
      secondary:
        if(item.marker == "●", do: current_position(item.secondary), else: item.secondary),
      depth: item.depth,
      connector?: item.connector?,
      last?: item.last?,
      ancestor_continues: item.ancestor_continues,
      active?: item.active?,
      unsafe?: item.unsafe?
    }
  end

  defp current_position(nil), do: "current position"
  defp current_position("current position"), do: "current position"
  defp current_position(secondary), do: "current position · " <> secondary

  defp display_label(%{id: @root_id, primary: primary}), do: "↩  " <> primary
  defp display_label(%{primary: primary}), do: primary

  defp select_active(%Picker{items: items} = picker) do
    selected = Enum.find_index(items, &(&1.marker == "●")) || 0
    %{picker | selected: selected}
  end

  defp gutters(_ancestors, 0), do: []

  defp gutters(ancestors, depth) do
    Enum.map(0..(depth - 1), &Map.get(ancestors, &1, false))
  end

  defp put_gutter(ancestors, position, continues?) when position >= 0,
    do: Map.put(ancestors, position, continues?)

  defp put_gutter(ancestors, _position, _continues?), do: ancestors

  defp subtree_active?(_tree, _entry, nil), do: false

  defp subtree_active?(tree, entry, active) do
    entry.id == active ||
      Enum.any?(ConversationTree.children(tree, entry.id), &subtree_active?(tree, &1, active))
  end

  defp filtered(%Picker{query: "", items: items}), do: items

  defp filtered(%Picker{items: items, query: query}) do
    matches = items |> Picker.filter(query) |> MapSet.new()
    Enum.filter(items, &MapSet.member?(matches, &1))
  end

  defp selected_item(%Picker{} = picker) do
    picker |> filtered() |> Enum.at(picker.selected)
  end

  # An incomplete tool batch is inspectable but not selectable: navigating there
  # would replay a tool or fabricate a result, which the runtime must never do.
  defp target(_entry, false), do: @unsafe_id
  defp target(%{kind: :message, message: %Message{role: :user, id: id}}, true), do: {:edit, id}
  defp target(%{id: id}, true), do: {:entry, id}

  defp label(%{kind: :message, message: %Message{role: :user} = message}),
    do: "user: " <> preview(message.content)

  defp label(%{kind: :message, message: %Message{role: :assistant} = message}) do
    content =
      case message.content do
        content when is_binary(content) and content != "" -> preview(content)
        _other -> if message.tool_calls in [nil, []], do: "(reasoning)", else: "(tool calls)"
      end

    "assistant: " <> content
  end

  defp label(%{kind: :message, message: %Message{role: :tool} = message}),
    do: "[#{message.tool_name || "tool"} result]"

  defp label(%{kind: :compaction, compaction: compaction}),
    do: "[context compacted · #{length(compaction.shadowed_message_ids)} messages]"

  defp label(_entry), do: "entry"

  defp secondary(_entry, false), do: "inspect only · incomplete tool batch"
  defp secondary(%{kind: :compaction}, true), do: "context checkpoint"
  defp secondary(_entry, true), do: nil

  defp marker(active, active) when not is_nil(active), do: "●"
  defp marker(nil, nil), do: "●"
  defp marker(_active, _id), do: " "

  defp search_text(%{kind: :message, message: %Message{} = message}) do
    Enum.join(Enum.reject([message.content, message.thinking, message.tool_name], &is_nil/1), " ")
  end

  defp search_text(%{kind: :compaction, compaction: compaction}) do
    Tackle.Lib.Compaction.checkpoint_body(compaction.summary_message) || "context compacted"
  end

  defp search_text(_entry), do: ""

  defp preview(nil), do: ""
  defp preview(text), do: text |> String.split("\n", parts: 2) |> hd() |> Util.truncate(60)

  defp dispatch(:close, state), do: {:noreply, %{state | overlay: nil}}

  defp dispatch(:previous, state) do
    {:tree, %{picker: picker}} = state.overlay
    {:noreply, %{state | overlay: {:tree, %{picker: Picker.move(picker, -1)}}}}
  end

  defp dispatch(:next, state) do
    {:tree, %{picker: picker}} = state.overlay
    {:noreply, %{state | overlay: {:tree, %{picker: Picker.move(picker, 1)}}}}
  end

  defp dispatch(:backspace, state) do
    {:tree, %{picker: picker}} = state.overlay
    {:noreply, %{state | overlay: {:tree, %{picker: Picker.backspace(picker)}}}}
  end

  defp dispatch({:insert, text}, state) do
    {:tree, %{picker: picker}} = state.overlay
    {:noreply, %{state | overlay: {:tree, %{picker: Picker.insert(picker, text)}}}}
  end

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
      | pending_operation: %{ref: ref, kind: :navigate},
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
  @spec apply_outcome(State.t(), map()) :: State.t()
  def apply_outcome(%State{} = state, outcome) do
    state = %{state | notice: notice(outcome)}
    state = Compaction.restore(state)

    case Map.get(outcome, :draft) do
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

  defp notice(%{mode: :edit, draft: %Message{content: content}}) when is_binary(content),
    do: "Editing an earlier message · submit to branch · workspace is unchanged"

  defp notice(%{destination_id: nil}),
    do: "Moved before the first message · workspace is unchanged"

  defp notice(_outcome), do: "Moved to an earlier position · workspace is unchanged"
end

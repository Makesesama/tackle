defmodule Tackle.CLI.TUI.Subagents do
  @moduledoc """
  Focus, selection, and lifecycle of the active-task sidebar.

  The sidebar is not an overlay: it opens beside the transcript whenever at
  least one delegated child is running and closes on its own when the last one
  settles. `focus/1` moves the keyboard into it so a running task can be
  selected and inspected, and `reconcile/1` keeps that selection valid while
  children finish.
  """

  alias Tackle.CLI.TUI.{Conversation, Inspector, State, Viewport}

  @doc "Whether any delegated child is currently running."
  @spec active?(State.t()) :: boolean()
  def active?(%State{} = state), do: tasks(state) != []

  @doc "Running delegated children in request order."
  @spec tasks(State.t()) :: [map()]
  def tasks(%State{} = state) do
    tool_tasks =
      Enum.filter(state.tool_activity, &match?(%{name: "subagent", status: :running}, &1))

    tracked_tasks =
      state.subagents
      |> Map.values()
      |> Enum.filter(&(&1[:status] == :running))
      |> Enum.reject(fn tracked ->
        Enum.any?(tool_tasks, &same_run?(&1, tracked))
      end)
      |> Enum.map(&tracked_task/1)
      |> Enum.sort_by(&Map.get(&1, :started_at_ms, 0))

    tool_tasks ++ tracked_tasks
  end

  @doc "Moves focus to the active-task sidebar, selecting the first task."
  @spec focus(State.t()) :: {:noreply, State.t()}
  def focus(%State{} = state) do
    case tasks(state) do
      [] ->
        {:noreply, %{state | notice: "No active subagents"}}

      [first | _] ->
        state = %{state | focus: :subagents, subagent_selected: first.id, notice: nil}
        {:noreply, Viewport.relayout(state)}
    end
  end

  @doc "Handles one resolved sidebar intent."
  @spec handle(atom(), State.t()) :: {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def handle(:leave, state), do: leave(state)
  def handle(:previous, state), do: {:noreply, move(state, -1)}
  def handle(:next, state), do: {:noreply, move(state, 1)}
  def handle(:inspect, state), do: inspect_selected(state)
  def handle(:ignore, state), do: {:noreply, state, render?: false}

  @doc "Returns sidebar focus to the composer."
  @spec leave(State.t()) :: {:noreply, State.t()}
  def leave(%State{} = state) do
    {:noreply, Viewport.relayout(%{state | focus: :composer, subagent_selected: nil})}
  end

  @doc """
  Keeps the sidebar consistent with the running children.

  Called after every tool transition: focus returns to the composer once the
  last child settles, and a selection that no longer exists moves to the first
  remaining task.
  """
  @spec reconcile(State.t()) :: State.t()
  def reconcile(%State{focus: :subagents} = state) do
    case tasks(state) do
      [] -> Viewport.relayout(%{state | focus: :composer, subagent_selected: nil})
      tasks -> %{state | subagent_selected: keep(tasks, state.subagent_selected)}
    end
  end

  def reconcile(%State{} = state), do: %{state | subagent_selected: nil}

  defp same_run?(tool, tracked) do
    run_id = Map.get(tracked, :run_id)
    is_binary(run_id) and Map.get(tool, :run_id) == run_id
  end

  defp tracked_task(tracked) do
    %{
      id: Map.get(tracked, :tool_call_id) || Map.get(tracked, :run_id),
      name: "subagent",
      status: :running,
      arguments: Map.get(tracked, :arguments),
      model: Map.get(tracked, :model),
      run_id: Map.get(tracked, :run_id),
      agent_ref: Map.get(tracked, :agent_ref),
      started_at_ms: Map.get(tracked, :started_at_ms),
      elapsed_ms: Map.get(tracked, :elapsed_ms)
    }
  end

  defp keep(tasks, selected) do
    if Enum.any?(tasks, &(&1.id == selected)), do: selected, else: hd(tasks).id
  end

  defp move(state, delta) do
    tasks = tasks(state)
    index = Enum.find_index(tasks, &(&1.id == state.subagent_selected)) || 0
    bounded = (index + delta) |> max(0) |> min(length(tasks) - 1)

    case Enum.at(tasks, bounded) do
      nil -> state
      task -> %{state | subagent_selected: task.id}
    end
  end

  # Details reuse the existing inspector over the child's inline card, so the
  # sidebar needs no second detail surface.
  defp inspect_selected(%State{} = state) do
    case Conversation.entry(state.conversation, "tool:#{state.subagent_selected}") do
      nil -> {:noreply, %{state | notice: "Task details unavailable"}}
      entry -> {:noreply, %{state | overlay: {:inspector, Inspector.build(state, entry)}}}
    end
  end
end

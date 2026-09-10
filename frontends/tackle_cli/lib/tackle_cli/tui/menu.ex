defmodule Tackle.CLI.TUI.Menu do
  @moduledoc """
  The search-first configuration menus: model, reasoning level, and settings.

  A menu is a `Picker` plus a *kind* that says what selecting a row means. This
  module builds the rows, translates menu keys into picker navigation, applies
  the chosen value through `Tackle.reconfigure/2`, and renders the popup.

  Configuration only makes sense when nothing is running, so opening a menu
  during a turn reports that rather than queueing a change. A reconfigure
  failure closes the menu and reports the reason while preserving both the
  conversation and the draft.

  The settings menu is intentionally empty: it holds configuration that is not
  the model or the reasoning level, and it says so instead of disappearing. The
  first real setting also needs an `apply/3` clause, because selecting a row is
  what writes the value.
  """

  alias ExRatatui.Command
  alias ExRatatui.Style
  alias ExRatatui.Widgets.List, as: SelectionList
  alias ExRatatui.Widgets.{Paragraph, Popup}
  alias Tackle.CLI.TUI.{Picker, State, Theme, Util}
  alias Tackle.Thinking

  @doc """
  Opens a menu of `kind` when the shell is idle.

  Returns a notice instead when a turn is active.
  """
  @spec open(atom(), State.t()) :: {:noreply, State.t()}
  def open(_kind, %State{active_turn: turn} = state) when not is_nil(turn) do
    {:noreply, %{state | notice: "Configuration is available when idle"}}
  end

  def open(_kind, %State{pending_operation: operation} = state) when not is_nil(operation) do
    {:noreply, %{state | notice: "Configuration is available when idle"}}
  end

  def open(kind, %State{} = state) do
    {:noreply,
     %{state | overlay: {:picker, %{kind: kind, picker: Picker.new(items(kind, state))}}}}
  end

  @doc "Handles one resolved menu intent."
  @spec handle(atom() | tuple(), State.t()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def handle(intent, %State{} = state), do: dispatch(intent, state)

  @doc """
  Applies a bracketed paste to the menu query.

  Whitespace is collapsed because a menu is a single-line search field.
  """
  @spec paste(State.t(), String.t()) :: State.t()
  def paste(%State{overlay: {:picker, picker}} = state, content) do
    query = picker.picker.query <> String.replace(content, ~r/\s+/u, " ")

    %{state | overlay: {:picker, %{picker | picker: Picker.new(picker.picker.items, query)}}}
  end

  @doc """
  Returns the menu rows for `kind`.

  Model rows search `provider ref id`, so a provider-qualified query outranks a
  proxy id such as `openrouter/openai/gpt-5`.
  """
  @spec items(atom(), State.t()) :: [Picker.item()]
  def items(:model, %State{} = state) do
    current = State.model_ref(state.agent_state)

    Enum.map(state.models, fn ref ->
      {provider, id} = split_model_ref(ref)

      %{
        id: ref,
        primary: id,
        secondary: provider && "[#{provider}]",
        marker: current_marker(ref, current),
        search: Enum.join(Enum.reject([provider, ref, id], &is_nil/1), " ")
      }
    end)
  end

  def items(:thinking, %State{} = state) do
    current = Thinking.from_llm_opts(state.agent_state.llm_opts)

    Enum.map(Thinking.levels(), fn level ->
      %{
        id: level,
        primary: level,
        secondary: thinking_description(level),
        marker: current_marker(level, current),
        search: level
      }
    end)
  end

  def items(:settings, _state), do: []

  @doc "Renders the open menu as a popup."
  @spec popup(State.t()) :: Popup.t()
  def popup(%State{overlay: {:picker, %{kind: kind, picker: picker}}}) do
    items = Picker.filtered(picker)
    selected = Util.clamp(picker.selected, 0, max(length(items) - 1, 0))

    content =
      case items do
        [] ->
          empty_menu(kind)

        items ->
          %SelectionList{
            items: Enum.map(items, &Picker.row/1),
            selected: selected,
            highlight_symbol: "› ",
            highlight_style: %Style{fg: :cyan, modifiers: [:bold]},
            style: %Style{fg: :white},
            scroll_padding: 2
          }
      end

    %Popup{
      content: content,
      block: Theme.panel_block(title(kind, picker.query, length(items)), :cyan),
      percent_width: 72,
      percent_height: 55
    }
  end

  defp dispatch(:close, state), do: {:noreply, %{state | overlay: nil}}

  defp dispatch(:previous, state) do
    {:picker, picker} = state.overlay

    {:noreply, %{state | overlay: {:picker, %{picker | picker: Picker.move(picker.picker, -1)}}}}
  end

  defp dispatch(:next, state) do
    {:picker, picker} = state.overlay

    {:noreply, %{state | overlay: {:picker, %{picker | picker: Picker.move(picker.picker, 1)}}}}
  end

  defp dispatch(:accept, state) do
    {:picker, %{kind: kind, picker: picker}} = state.overlay

    case Picker.selected(picker) do
      nil -> {:noreply, state, render?: false}
      item -> apply_selection(kind, item, state)
    end
  end

  defp dispatch(:backspace, state) do
    {:picker, picker} = state.overlay

    {:noreply, %{state | overlay: {:picker, %{picker | picker: Picker.backspace(picker.picker)}}}}
  end

  defp dispatch({:insert, text}, state) do
    {:picker, picker} = state.overlay

    {:noreply,
     %{state | overlay: {:picker, %{picker | picker: Picker.insert(picker.picker, text)}}}}
  end

  defp dispatch(:ignore, state), do: {:noreply, state, render?: false}

  defp apply_selection(:model, item, state), do: reconfigure(state, model: item.id)
  defp apply_selection(:thinking, item, state), do: reconfigure(state, thinking: item.id)

  defp reconfigure(state, opts) do
    ref = make_ref()
    agent_ref = state.agent_ref

    command =
      Command.async(
        fn -> Tackle.reconfigure(agent_ref, opts) end,
        &{:tui_operation_result, ref, :reconfigure, &1}
      )

    state = %{
      state
      | pending_operation: %{ref: ref, kind: :reconfigure},
        overlay: nil,
        activity: "reconfiguring",
        error: nil,
        outcome: nil
    }

    {:noreply, state, commands: [command]}
  end

  defp current_marker(value, value), do: "✓"
  defp current_marker(_value, _current), do: " "

  defp split_model_ref(ref) do
    case String.split(ref, "/", parts: 2) do
      [provider, id] when provider != "" and id != "" -> {provider, id}
      _unqualified -> {nil, ref}
    end
  end

  defp thinking_description("off"), do: "No reasoning"
  defp thinking_description("minimal"), do: "Briefest reasoning"
  defp thinking_description("low"), do: "Light reasoning"
  defp thinking_description("medium"), do: "Balanced reasoning"
  defp thinking_description("high"), do: "Deep reasoning"
  defp thinking_description("xhigh"), do: "Maximum reasoning"
  defp thinking_description(_level), do: nil

  defp empty_menu(:settings) do
    %Paragraph{
      text:
        " No settings yet.\n\n The model and the reasoning level have their own menus; anything else the harness makes configurable will appear here.",
      style: %Style{fg: :dark_gray}
    }
  end

  defp empty_menu(:model),
    do: %Paragraph{text: " No models match.", style: %Style{fg: :dark_gray}}

  defp empty_menu(_kind),
    do: %Paragraph{text: " No options match.", style: %Style{fg: :dark_gray}}

  defp title(kind, query, count) do
    label =
      case kind do
        :model -> "Model"
        :thinking -> "Reasoning level"
        :settings -> "Settings"
      end

    filter = if query == "", do: "", else: " filter “#{Util.truncate(query, 24)}” ·"

    " #{label} ·#{filter} #{count} #{if count == 1, do: "entry", else: "entries"} · type to filter · Enter select · Esc close "
  end
end

defmodule Tackle.CLI.TUI.View do
  @moduledoc """
  The scene: a flat list of widgets and the rectangles they occupy.

  The shell is transcript-first. A one-row header shows the model, the
  reasoning level, and the turn state; the transcript owns the flexible middle
  of the screen; the composer sits below it with a border whose color and title
  say whether the shell is idle, drafting during a turn, or browsing. Optional
  reading, status, and hint rows appear only when the terminal has rows to
  spare.

  Layout is computed once per frame from the terminal size and the draft's
  logical line count, so the widget list and the rectangles can never disagree.
  Overlays are appended last so they paint above everything else; each overlay's
  own popup is rendered by the module that owns its state.
  """

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, Paragraph, Popup, Textarea, WidgetList}

  alias Tackle.CLI.TUI.{
    Conversation,
    Inspector,
    Layout,
    Menu,
    MessageView,
    Search,
    State,
    StatusView,
    Theme,
    Viewport
  }

  alias Tackle.Thinking

  @doc """
  Builds the complete scene for a frame as `{widget, rect}` pairs.
  """
  @spec scene(State.t(), ExRatatui.Frame.t()) :: [{struct(), Rect.t()}]
  def scene(%State{} = state, _frame) do
    {width, height} = state.size

    regions =
      Layout.regions(width, height, state.draft_lines, Viewport.reading?(state.conversation))

    [
      {header_widget(state, width), regions.header},
      {transcript_widget(state), regions.transcript}
    ] ++
      reading_widgets(regions.reading, state.conversation) ++
      status_widgets(regions.status, state, width) ++
      [{composer_widget(state), regions.composer}] ++
      hints_widgets(regions.hints, state, width) ++
      overlay_widgets(state, width, height)
  end

  # -- header and transcript ----------------------------------------------

  defp header_widget(state, width) do
    %Paragraph{text: [MessageView.row(header_spans(state, width), %Style{})], style: %Style{}}
  end

  # The header drops the least important segment first: the model, then the
  # reasoning level, then the turn state, which is never dropped.
  defp header_spans(state, width) do
    model = State.model_ref(state.agent_state) || "configured default"
    thinking = Thinking.from_llm_opts(state.agent_state.llm_opts)
    separator = MessageView.span("  ·  ", Theme.style(:subtle))

    base = [MessageView.span(" Tackle", Theme.style(:accent))]
    model_part = [separator, MessageView.span(model, Theme.style(:muted))]
    thinking_part = [separator, MessageView.span("thinking #{thinking}", Theme.style(:muted))]

    status_part = [
      separator,
      MessageView.span(StatusView.status_label(state), StatusView.status_style(state))
    ]

    variants = [
      base ++ model_part ++ thinking_part ++ status_part,
      base ++ thinking_part ++ status_part,
      base ++ status_part
    ]

    Enum.find(variants, List.last(variants), &(spans_width(&1) <= max(width, 1)))
  end

  defp spans_width(spans) do
    Enum.reduce(spans, 0, fn span, total -> total + MessageView.display_width(span.content) end)
  end

  defp transcript_widget(state) do
    %WidgetList{
      items: state.conversation.visible_items,
      scroll_offset: state.conversation.visible_offset
    }
  end

  defp reading_widgets(nil, _conversation), do: []

  defp reading_widgets(rect, conversation) do
    case Conversation.affordance(conversation) do
      nil ->
        [{%Paragraph{text: ""}, rect}]

      text ->
        [
          {
            %Paragraph{
              text: [
                MessageView.row(
                  [MessageView.span(" " <> text, Theme.style(:accent))],
                  %Style{}
                )
              ]
            },
            rect
          }
        ]
    end
  end

  # -- optional rows -------------------------------------------------------

  defp status_widgets(nil, _state, _width), do: []

  defp status_widgets(rect, state, width) do
    [{StatusView.status_widget(state, width), rect}]
  end

  defp hints_widgets(nil, _state, _width), do: []

  defp hints_widgets(rect, state, width) do
    [{StatusView.hints_widget(state, width), rect}]
  end

  # -- composer ------------------------------------------------------------

  defp composer_widget(state) do
    %Textarea{
      state: state.input,
      placeholder: composer_placeholder(state),
      placeholder_style: Theme.style(:subtle),
      cursor_line_style: %Style{bg: {:indexed, 235}},
      block: %Block{
        title: composer_title(state),
        title_style: %Style{fg: composer_color(state)},
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: composer_color(state)}
      }
    }
  end

  defp composer_title(%State{focus: :transcript}), do: " Browsing · Esc or F4 returns "
  defp composer_title(%State{active_turn: nil}), do: " Prompt "
  defp composer_title(%State{}), do: " Draft · next turn (not queued) "

  defp composer_placeholder(%State{focus: :transcript}),
    do: "Transcript focused — typing is off · ↑/↓ move · Enter inspect · y copy"

  defp composer_placeholder(%State{active_turn: nil}),
    do: "Ask Tackle… Enter sends · Shift+Enter or Ctrl+J newline · F1 model"

  defp composer_placeholder(%State{}), do: "Draft the next instruction — kept, not queued"

  defp composer_color(%State{focus: :transcript}), do: :cyan
  defp composer_color(%State{active_turn: nil}), do: :green
  defp composer_color(%State{}), do: :dark_gray

  # -- overlays ------------------------------------------------------------

  defp overlay_widgets(%State{overlay: nil}, _width, _height), do: []

  defp overlay_widgets(state, width, height) do
    [{overlay_widget(state), %Rect{x: 0, y: 0, width: width, height: height}}]
  end

  defp overlay_widget(%State{overlay: {:picker, _}} = state), do: Menu.popup(state)
  defp overlay_widget(%State{overlay: {:inspector, _}} = state), do: Inspector.popup(state)
  defp overlay_widget(%State{overlay: {:search, _}} = state), do: Search.popup(state)

  defp overlay_widget(%State{overlay: {:confirm_quit, confirm}}) do
    text =
      case confirm.reason do
        :draft -> " Quit Tackle?\n\n Your unsent draft will be lost."
        :turn -> " Quit Tackle?\n\n An active turn will be stopped."
      end

    %Popup{
      content: %Paragraph{text: text, style: %Style{fg: :white}},
      block: Theme.panel_block(" Confirm quit · Y/Enter quit · N/Esc cancel ", :yellow),
      percent_width: 50,
      percent_height: 25
    }
  end

  defp overlay_widget(%State{overlay: {:confirm_new_session, confirm}}) do
    text =
      case confirm.reason do
        :idle ->
          " Start a new session?\n\n This conversation is closed and a fresh one begins."

        :turn ->
          " Start a new session?\n\n The active turn is stopped and a fresh conversation begins."
      end

    %Popup{
      content: %Paragraph{text: text, style: %Style{fg: :white}},
      block: Theme.panel_block(" Confirm new session · Y/Enter start · N/Esc cancel ", :yellow),
      percent_width: 50,
      percent_height: 25
    }
  end
end

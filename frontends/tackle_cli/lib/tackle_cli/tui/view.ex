defmodule Tackle.CLI.TUI.View do
  @moduledoc """
  The scene: a flat list of widgets and the rectangles they occupy.

  The shell is transcript-first. A one-row header shows the model and
  reasoning level; the transcript owns the flexible middle of the screen;
  a quiet divider introduces the composer. Turn state lives in the status row
  (or the header on short terminals), never both. Optional reading, status,
  and hint rows appear only when the terminal has rows to spare.

  Layout is computed once per frame from the terminal size and the draft's
  wrapped row count, so the widget list and the rectangles can never disagree.
  Overlays are appended last so they paint above everything else; each overlay's
  own popup is rendered by the module that owns its state.
  """

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, Paragraph, Popup}
  alias Tackle.CLI.Widgets.Input

  alias Tackle.CLI.TUI.{
    Browser,
    Conversation,
    Inspector,
    Layout,
    Menu,
    MessageView,
    Search,
    State,
    StatusView,
    Theme,
    Tree,
    UsageChart,
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
      {header_widget(state, width, is_nil(regions.status)), regions.header},
      {transcript_widget(state), regions.transcript}
    ] ++
      reading_widgets(regions.reading, state.conversation) ++
      status_widgets(regions.status, state, width) ++
      [{composer_widget(state), regions.composer}] ++
      hints_widgets(regions.hints, state, width) ++
      overlay_widgets(state, width, height)
  end

  # -- header and transcript ----------------------------------------------

  defp header_widget(state, width, show_status?) do
    %Paragraph{text: [MessageView.row(header_spans(state, width, show_status?), %Style{})]}
  end

  # Keep model identity before reasoning. On short terminals the header also
  # carries turn state, which takes priority over configuration and branding.
  defp header_spans(state, width, show_status?) do
    model = State.model_ref(state.agent_state) || "configured default"
    thinking = Thinking.from_llm_opts(state.agent_state.llm_opts)
    separator = MessageView.span("  ·  ", Theme.style(:subtle))

    base = [MessageView.span(" Tackle", Theme.bold(Theme.style(:text)))]
    model_part = [separator, MessageView.span(model, Theme.style(:muted))]
    thinking_part = [separator, MessageView.span("thinking #{thinking}", Theme.style(:muted))]

    status = MessageView.span(StatusView.status_label(state), StatusView.status_style(state))
    status_part = if show_status?, do: [separator, status], else: []

    variants = [
      base ++ model_part ++ thinking_part ++ status_part,
      base ++ model_part ++ status_part,
      base ++ status_part,
      if(show_status?, do: [status], else: base)
    ]

    Enum.find(variants, List.last(variants), &(spans_width(&1) <= max(width, 1)))
  end

  defp spans_width(spans) do
    Enum.reduce(spans, 0, fn span, total -> total + MessageView.display_width(span.content) end)
  end

  defp transcript_widget(state) do
    if state.focus == :transcript,
      do: Browser.widget(state),
      else: Conversation.widget(state.conversation)
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
    %Input{
      state: state.input,
      placeholder: composer_placeholder(state),
      focused: state.focus == :composer and is_nil(state.overlay),
      block: %Block{
        title: composer_title(state),
        title_style: Theme.style(:muted),
        borders: [:top],
        border_style: Theme.style(:subtle),
        padding: {1, 1, 0, 1}
      }
    }
  end

  defp composer_title(%State{focus: :transcript, browse_page: page}),
    do: " Browsing · #{page} · ←/→ pages · Esc/F4 back "

  defp composer_title(%State{active_turn: nil, pending_operation: nil}), do: " › "
  defp composer_title(%State{}), do: " Draft · not queued "

  defp composer_placeholder(%State{focus: :transcript}),
    do: "Transcript focused"

  defp composer_placeholder(%State{active_turn: nil, pending_operation: nil}),
    do: "What would you like to build?"

  defp composer_placeholder(%State{}), do: "Write the next instruction…"

  # -- overlays ------------------------------------------------------------

  defp overlay_widgets(%State{overlay: nil}, _width, _height), do: []

  defp overlay_widgets(state, width, height) do
    [{overlay_widget(state), %Rect{x: 0, y: 0, width: width, height: height}}]
  end

  defp overlay_widget(%State{overlay: {:picker, _}} = state), do: Menu.popup(state)
  defp overlay_widget(%State{overlay: {:tree, _}} = state), do: Tree.popup(state)
  defp overlay_widget(%State{overlay: {:inspector, _}} = state), do: Inspector.popup(state)
  defp overlay_widget(%State{overlay: {:search, _}} = state), do: Search.popup(state)
  defp overlay_widget(%State{overlay: {:usage_chart, _}} = state), do: UsageChart.popup(state)

  defp overlay_widget(%State{overlay: {:confirm_quit, confirm}}) do
    text =
      case confirm.reason do
        :draft -> " Quit Tackle?\n\n Your unsent draft will be lost."
        :turn -> " Quit Tackle?\n\n An active turn will be stopped."
      end

    %Popup{
      content: %Paragraph{text: text, style: Theme.style(:text)},
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
      content: %Paragraph{text: text, style: Theme.style(:text)},
      block: Theme.panel_block(" Confirm new session · Y/Enter start · N/Esc cancel ", :yellow),
      percent_width: 50,
      percent_height: 25
    }
  end
end

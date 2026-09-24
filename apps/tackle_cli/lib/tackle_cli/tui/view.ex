defmodule Tackle.CLI.TUI.View do
  @moduledoc """
  The scene: a flat list of widgets and the rectangles they occupy.

  The shell is transcript-first. A header shows the model and
  reasoning level; graphics-capable terminals reserve three rows for a small
  right-aligned logo while other terminals use a one-row text header.
  The transcript owns the flexible middle of the screen;
  a rounded input bar encloses the composer. Turn state and the `?` shortcut
  cue share a row below the bar, with reading position there when relevant.
  The header carries turn state only on short terminals.

  Layout is computed once per frame from the terminal size and the draft's
  wrapped row count, so the widget list and the rectangles can never disagree.
  Overlays are appended last so they paint above everything else; each overlay's
  own popup is rendered by the module that owns its state.
  """

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, Paragraph, Popup}
  alias Tackle.CLI.Widgets.Input
  alias Tackle.CLI.Widgets.Subagents, as: TaskSidebar

  alias Tackle.CLI.TUI.{
    Browser,
    Conversation,
    Help,
    Inspector,
    Layout,
    Menu,
    MessageView,
    Search,
    State,
    StatusView,
    Subagents,
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
      Layout.regions(
        width,
        height,
        state.draft_lines,
        Viewport.reading?(state.conversation),
        Subagents.active?(state),
        not is_nil(state.header_image)
      )

    [
      {header_widget(state, width, is_nil(regions.status), regions.header), regions.header},
      {transcript_widget(state), regions.transcript}
    ] ++
      header_graphic(state, regions.header) ++
      sidebar_widgets(regions.sidebar, state) ++
      reading_widgets(regions.reading, state.conversation) ++
      status_widgets(regions.status, state, width) ++
      [{composer_widget(state), regions.composer}] ++
      overlay_widgets(state, width, height)
  end

  # -- header and transcript ----------------------------------------------

  defp header_widget(state, width, show_status?, header) do
    %Paragraph{
      text: [MessageView.row(header_spans(state, width, show_status?, header), %Style{})]
    }
  end

  defp header_graphic(%{header_image: nil}, _rect), do: []
  defp header_graphic(_state, %{height: height}) when height < 2, do: []

  defp header_graphic(state, rect) do
    # The five-column mark sits directly before the five-column word suffix.
    # Its second row is reserved, never painted over the transcript.
    [{state.header_image, %Rect{x: rect.x + rect.width - 10, y: rect.y, width: 5, height: 2}}]
  end

  # Keep model identity before reasoning. On short terminals the header also
  # carries turn state, which takes priority over configuration and branding.
  defp header_spans(state, width, show_status?, header) do
    model = State.model_ref(state.agent_state) || "configured default"
    thinking = Thinking.from_llm_opts(state.agent_state.llm_opts)
    separator = MessageView.span("  ·  ", Theme.style(:subtle))

    model_part = [MessageView.span(model, Theme.style(:muted))]
    thinking_part = [separator, MessageView.span("thinking #{thinking}", Theme.style(:muted))]

    status = MessageView.span(StatusView.status_label(state), StatusView.status_style(state))
    status_part = if show_status?, do: [separator, status], else: []

    variants = [
      model_part ++ thinking_part ++ status_part,
      model_part ++ status_part,
      if(show_status?, do: [status], else: []),
      []
    ]

    graphic? = header.height >= 2

    brand =
      if graphic?,
        do: [MessageView.span("ackle", Theme.bold(Theme.style(:text)))],
        else: [MessageView.span("Tackle", Theme.bold(Theme.style(:text)))]

    brand_width = if graphic?, do: 10, else: spans_width(brand)

    # Short-terminal turn state must remain visible even when the brand would
    # fit by itself but not alongside the status label.
    if width > brand_width and
         (not show_status? or spans_width([status]) + 1 + brand_width <= width) do
      space = width - brand_width - 1
      left = Enum.find(variants, [], &(spans_width(&1) <= space))
      padding = width - brand_width - spans_width(left)
      brand_gap = if graphic?, do: 5, else: 0
      left ++ [MessageView.span(String.duplicate(" ", padding + brand_gap))] ++ brand
    else
      Enum.find(variants, [], &(spans_width(&1) <= max(width, 1)))
    end
  end

  defp spans_width(spans) do
    Enum.reduce(spans, 0, fn span, total -> total + MessageView.display_width(span.content) end)
  end

  defp transcript_widget(state) do
    if state.focus == :transcript,
      do: Browser.widget(state),
      else: Conversation.widget(state.conversation)
  end

  defp sidebar_widgets(nil, _state), do: []

  defp sidebar_widgets(rect, state) do
    [
      {TaskSidebar.from_activity(
         Subagents.tasks(state),
         state.subagent_selected,
         state.spinner_frame
       ), rect}
    ]
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

  # -- composer ------------------------------------------------------------

  defp composer_widget(state) do
    {width, height} = state.size
    focused? = state.focus == :composer and is_nil(state.overlay)

    block =
      if Layout.composer_box?(width, height) do
        %Block{
          title: composer_title(state),
          title_style: Theme.style(:muted),
          borders: [:all],
          border_type: :rounded,
          border_style: Theme.style(if(focused?, do: :accent_soft, else: :subtle)),
          padding: {1, 1, 0, 0}
        }
      end

    %Input{
      state: state.input,
      placeholder: composer_placeholder(state),
      focused: focused?,
      block: block
    }
  end

  defp composer_title(%State{focus: :subagents}), do: " Message "
  defp composer_title(%State{focus: :transcript}), do: " Message "

  defp composer_title(%State{active_turn: nil, pending_operation: nil}), do: " Message "
  defp composer_title(%State{}), do: " Queue next message "

  defp composer_placeholder(%State{focus: :subagents}), do: "Subagents focused"

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

  defp overlay_widget(%State{overlay: {:help, _}} = state), do: Help.popup(state)
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

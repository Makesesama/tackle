defmodule Tackle.CLI.TUI.Help do
  @moduledoc "Shortcut reference opened with `?` from an empty composer or browse pane."

  alias ExRatatui.Widgets.{Paragraph, Popup}
  alias Tackle.CLI.TUI.{State, Theme, Util}

  @shortcuts [
    "? / Esc close · ↑/↓ scroll",
    "",
    "Compose",
    "Enter         send draft",
    "Ctrl+J        newline",
    "↑/↓           prompt history",
    "Ctrl+P/N      prompt history",
    "Ctrl+B/F      move by word",
    "Esc           cancel turn",
    "Ctrl+C        quit",
    "Alt+N         new session",
    "Ctrl+K        compact context",
    "Ctrl+T        toggle thinking",
    "F1/F2/F3      model / reasoning / settings",
    "F4/F5/F6/F7   browse / tree / usage / tasks",
    "Page ↑/↓      scroll transcript",
    "Alt+< / >     oldest / latest",
    "",
    "Browse (F4)",
    "↑/↓           select / scroll",
    "←/→ or Tab    switch page",
    "Enter         inspect entry",
    "Y / A         copy source / transcript",
    "Ctrl+F        search transcript",
    "R             refresh page",
    "Esc / F4      return to composer",
    "",
    "Tasks (F7)",
    "↑/↓           select task",
    "Enter         details",
    "Esc           back"
  ]

  @doc "Opens the reference without altering the draft or current focus."
  @spec open(State.t()) :: {:noreply, State.t()}
  def open(%State{} = state), do: {:noreply, %{state | overlay: {:help, %{offset: 0}}}}

  @doc "Handles navigation in the reference."
  @spec handle(:close | :previous | :next | :ignore, State.t()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def handle(:close, %State{} = state), do: {:noreply, %{state | overlay: nil}}

  def handle(direction, %State{overlay: {:help, help}} = state)
      when direction in [:previous, :next] do
    {_width, height} = state.size
    page_size = max(height - 2, 1)
    last_offset = max(length(@shortcuts) - page_size, 0)
    delta = if(direction == :next, do: 1, else: -1)
    offset = help.offset |> Kernel.+(delta) |> max(0) |> min(last_offset)
    {:noreply, %{state | overlay: {:help, %{help | offset: offset}}}}
  end

  def handle(:ignore, %State{} = state), do: {:noreply, state, render?: false}

  @doc "Builds a scrollable key reference that also fits small terminals."
  @spec popup(State.t()) :: Popup.t()
  def popup(%State{overlay: {:help, %{offset: offset}}, size: {width, height}}) do
    page_size = max(height - 2, 1)

    lines =
      @shortcuts
      |> Enum.drop(offset)
      |> Enum.take(page_size)
      |> Enum.map(&Util.truncate(&1, max(width - 2, 1)))

    %Popup{
      content: %Paragraph{text: Enum.join(lines, "\n"), style: Theme.style(:muted)},
      block: Theme.panel_block(" Shortcuts · ↑/↓ scroll · ?/Esc close ", :cyan),
      percent_width: 100,
      percent_height: 100
    }
  end
end

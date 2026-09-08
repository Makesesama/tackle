defmodule Tackle.CLI.TUI do
  @moduledoc """
  Minimal terminal presentation for the CLI frontend.

  This is intentionally only presentation scaffolding. Adapter loading and model
  validation belong to the root harness; this module only receives the model
  value selected by CLI parsing.
  """

  alias ExRatatui.Event.Key
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, Paragraph}

  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts \\ []) do
    model = Keyword.get(opts, :model)

    ExRatatui.run(fn terminal ->
      with :ok <- draw_welcome(terminal, model) do
        wait_for_exit()
      end
    end)
  end

  @doc false
  @spec welcome_widget(String.t() | nil) :: Paragraph.t()
  def welcome_widget(model) do
    selected = model || "configured default"

    %Paragraph{
      text: "Tackle CLI\n\nModel: #{selected}\n\nPress q or Esc to exit.",
      alignment: :center,
      wrap: true,
      style: %Style{fg: :green, modifiers: [:bold]},
      block: %Block{
        title: " Tackle ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :cyan}
      }
    }
  end

  defp draw_welcome(terminal, model) do
    {width, height} = ExRatatui.terminal_size()
    rect = %Rect{x: 0, y: 0, width: width, height: height}
    ExRatatui.draw(terminal, [{welcome_widget(model), rect}])
  end

  defp wait_for_exit do
    case ExRatatui.poll_event(250) do
      %Key{code: code, kind: "press"} when code in ["q", "esc"] -> :ok
      {:error, reason} -> {:error, reason}
      _event -> wait_for_exit()
    end
  end
end

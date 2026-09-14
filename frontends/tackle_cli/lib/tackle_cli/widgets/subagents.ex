defmodule Tackle.CLI.Widgets.Subagents do
  @moduledoc """
  Native sidebar for active delegated tasks.

  The widget receives the profile, model, assignment, current live work, and
  locally observed elapsed time. Rust owns the compact task layout, wrapping,
  and minimal sidebar chrome so the surface can evolve independently.
  """

  alias ExRatatui.Layout.Rect
  alias Tackle.CLI.Native
  alias Tackle.CLI.TUI.{MessageView, Theme, ToolView}
  alias Tackle.CLI.Widgets.{Conversation, Surface}

  defstruct tasks: [], selected: nil, spinner_frame: 0

  @type t :: %__MODULE__{
          tasks: [map()],
          selected: non_neg_integer() | nil,
          spinner_frame: non_neg_integer()
        }

  @doc "Returns a sidebar containing only currently running subagent calls."
  @spec from_activity([map()], String.t() | nil, non_neg_integer()) :: t()
  def from_activity(activity, selected_id \\ nil, spinner_frame \\ 0) do
    tasks =
      for %{name: "subagent", status: :running} = task <- activity do
        args = ToolView.arguments(Map.get(task, :arguments))

        %{
          id: Map.get(task, :id),
          profile: value(args, :profile) || "subagent",
          model: value(task, :model),
          summary: summary(value(args, :prompt)),
          work: work_text(Map.get(task, :subagent_work)),
          elapsed: elapsed(task[:elapsed_ms])
        }
      end

    selected = Enum.find_index(tasks, &(&1.id == selected_id))
    %__MODULE__{tasks: tasks, selected: selected, spinner_frame: spinner_frame}
  end

  @doc "Renders active tasks through Tackle's owned native surface."
  @spec render(t(), Rect.t()) :: [{struct(), Rect.t()}]
  def render(%__MODULE__{tasks: []}, %Rect{}), do: []

  def render(%__MODULE__{} = widget, %Rect{} = rect) do
    tasks = Enum.map(widget.tasks, &wire_task/1)

    {:ok, rows} =
      Native.subagents_render(
        tasks,
        rect.width,
        rect.height,
        style(:accent_soft),
        style(:muted),
        style(:text),
        widget.selected,
        widget.spinner_frame
      )

    Surface.place(rows, rect)
  end

  defp wire_task(task) do
    {
      task.profile |> to_string() |> MessageView.sanitize(),
      task.model |> model_text() |> MessageView.sanitize(),
      task.summary |> to_string() |> MessageView.sanitize(),
      task.work |> to_string() |> MessageView.sanitize(),
      task.elapsed
    }
  end

  defp model_text(model) when is_binary(model) and model != "", do: model
  defp model_text(_model), do: "model pending"

  defp summary(prompt) when is_binary(prompt) do
    words = prompt |> MessageView.sanitize() |> String.split()

    case words do
      [] ->
        "Working"

      words ->
        words
        |> Enum.take(6)
        |> Enum.join(" ")
        |> then(&if(length(words) > 6, do: &1 <> "…", else: &1))
    end
  end

  defp summary(_prompt), do: "Working"

  defp work_text(work) when is_binary(work) and work != "", do: work
  defp work_text(_work), do: "Starting…"

  defp elapsed(ms) when is_integer(ms) and ms >= 0 do
    seconds = div(ms, 1_000)
    if seconds < 60, do: "#{seconds}s", else: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  defp elapsed(_ms), do: nil

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp style(tone), do: tone |> Theme.style() |> Conversation.style()

  defimpl ExRatatui.Widget do
    defdelegate render(widget, rect), to: Tackle.CLI.Widgets.Subagents
  end
end

defmodule Tackle.CLI.Output.Progress do
  @moduledoc """
  Terminal-aware progress for one-shot CLI runs.

  Progress owns a command-local `Owl.LiveScreen` on stderr. This keeps the
  command result on stdout and avoids sharing Owl's application-wide stdout
  screen with unrelated commands. When stderr is not a terminal, progress is
  disabled and produces no output.
  """

  alias Tackle.Lib.Event

  defstruct [:screen, :spinner_id, :width]

  @type t :: %__MODULE__{screen: pid(), spinner_id: reference(), width: pos_integer()}
  @type handle :: t() | :disabled

  @doc "Starts progress when stderr is an interactive terminal."
  @spec start(keyword()) :: handle()
  def start(opts \\ []) do
    device = opts |> Keyword.get(:device, :stderr) |> normalize_device()

    with true <- Keyword.get(opts, :enabled, terminal?(device)),
         width when is_integer(width) and width > 0 <- Owl.IO.columns(device),
         {:ok, screen} <- Owl.LiveScreen.start_link(device: device, refresh_every: 60) do
      start_spinner(screen, width)
    else
      _other -> :disabled
    end
  rescue
    _exception -> :disabled
  catch
    _kind, _reason -> :disabled
  end

  @doc "Projects one harness event onto the current progress line."
  @spec event(handle(), Event.t()) :: handle()
  def event(:disabled, %Event{}), do: :disabled

  def event(%__MODULE__{} = progress, %Event{} = event) do
    case event_label(event) do
      nil -> progress
      label -> update(progress, label)
    end
  end

  @doc "Leaves one settled progress line and releases the command-local screen."
  @spec finish(handle(), {:ok, term()} | {:error, term()}) :: :ok
  def finish(:disabled, _result), do: :ok

  def finish(%__MODULE__{} = progress, result) do
    {label, resolution} =
      case result do
        {:ok, _value} -> {"Done", :ok}
        {:error, _reason} -> {"Failed", :error}
      end

    Owl.Spinner.stop(
      id: progress.spinner_id,
      resolution: resolution,
      label: truncate(progress, label)
    )

    Owl.LiveScreen.flush(progress.screen)
    GenServer.stop(progress.screen)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc false
  @spec event_label(Event.t()) :: String.t() | nil
  def event_label(%Event{type: :status_change, data: data}),
    do: status_label(value(data, :status))

  def event_label(%Event{type: :tool_start, data: data}) do
    name = value(data, :name) || "tool"
    "Running #{name}#{target(name, value(data, :arguments))}…"
  end

  def event_label(%Event{type: :tool_execution_end, data: data}) do
    name = value(data, :name) || "tool"

    case value(data, :status) do
      status when status in [:failed, "failed"] -> "#{name} failed"
      _other -> "Completed #{name}"
    end
  end

  def event_label(%Event{type: :subagent_started, data: data}) do
    profile = value(data, :profile) || "subagent"
    "Running #{profile} subagent…"
  end

  def event_label(%Event{type: :subagent_progress, data: data}),
    do: activity_label(value(data, :activity))

  def event_label(%Event{type: :compaction_start}), do: "Compacting context…"
  def event_label(%Event{type: :compaction_retry}), do: "Retrying compaction…"
  def event_label(%Event{type: :retry_start}), do: "Retrying provider request…"
  def event_label(%Event{type: :message_delta, data: %{field: :reasoning}}), do: "Thinking…"
  def event_label(%Event{type: :message_delta}), do: "Writing response…"
  def event_label(%Event{}), do: nil

  defp status_label(status) when status in [:thinking, "thinking"], do: "Thinking…"
  defp status_label(status) when status in [:acting, "acting"], do: "Working…"
  defp status_label(status) when status in [:completed, "completed"], do: nil
  defp status_label(status) when is_atom(status) or is_binary(status), do: humanize(status) <> "…"
  defp status_label(_status), do: nil

  defp activity_label(activity) when is_binary(activity) and activity != "", do: activity
  defp activity_label(_activity), do: nil

  defp start_spinner(screen, width) do
    progress = %__MODULE__{screen: screen, spinner_id: make_ref(), width: width}

    case Owl.Spinner.start(
           id: progress.spinner_id,
           live_screen_server: screen,
           labels: [processing: truncate(progress, "Starting agent…")]
         ) do
      {:ok, _spinner} ->
        progress

      _other ->
        GenServer.stop(screen)
        :disabled
    end
  end

  defp update(progress, label) do
    if Process.alive?(progress.screen) do
      Owl.Spinner.update_label(id: progress.spinner_id, label: truncate(progress, label))
    end

    progress
  end

  defp truncate(progress, label) do
    Owl.Data.truncate(label, max(progress.width - 2, 1))
  end

  defp terminal?(device) do
    is_integer(Owl.IO.columns(device)) and is_integer(Owl.IO.rows(device))
  end

  # Owl.IO only aliases :stdio to the Erlang device name for geometry calls;
  # IO itself aliases :stderr. Normalize explicitly so LiveScreen can measure it.
  defp normalize_device(:stderr), do: :standard_error
  defp normalize_device(device), do: device

  defp target(name, arguments) when is_map(arguments) do
    name
    |> to_string()
    |> target_candidate(arguments)
    |> format_target()
  end

  defp target(_name, _arguments), do: ""

  defp target_candidate("bash", arguments), do: value(arguments, :command)
  defp target_candidate("read", arguments), do: value(arguments, :path)
  defp target_candidate("write", arguments), do: value(arguments, :path)
  defp target_candidate("edit", arguments), do: value(arguments, :path)
  defp target_candidate("subagent", arguments), do: value(arguments, :profile)

  defp target_candidate(_name, arguments),
    do: value(arguments, :path) || value(arguments, :command)

  defp format_target(text) when is_binary(text) and text != "", do: " · " <> first_line(text)
  defp format_target(_target), do: ""

  defp first_line(text) do
    text
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.trim()
  end

  defp humanize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
end

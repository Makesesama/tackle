defmodule Tackle.CLI.TUI.UsageChart do
  @moduledoc """
  The asynchronous chronological token-usage overlay.

  Usage is loaded as a durable snapshot so scanning all session journals never
  blocks the TUI process. The renderer keeps the original samples and derives
  width-sensitive UTC buckets on every frame, allowing terminal resize without
  another disk read.
  """

  alias ExRatatui.Command
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, Chart, Paragraph, Popup}
  alias ExRatatui.Widgets.Chart.{Axis, Dataset}
  alias Tackle.CLI.TUI.{State, Theme, Util}
  alias Tackle.Lib.Usage
  alias Tackle.Session.UsageTimeline

  @intervals [
    1,
    60,
    5 * 60,
    15 * 60,
    60 * 60,
    6 * 60 * 60,
    12 * 60 * 60,
    24 * 60 * 60,
    7 * 24 * 60 * 60,
    30 * 24 * 60 * 60,
    90 * 24 * 60 * 60,
    365 * 24 * 60 * 60
  ]

  @type mode :: :current | :all

  @doc "Opens the chart in current-session mode, using its cached snapshot when present."
  @spec open(State.t()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def open(%State{} = state), do: load(state, :current)

  @doc "Handles one intent while the chart overlay owns the keyboard."
  @spec handle(:close | :toggle | :reload | :ignore, State.t()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def handle(:close, %State{} = state), do: {:noreply, %{state | overlay: nil}}

  def handle(:toggle, %State{overlay: {:usage_chart, %{mode: mode}}} = state) do
    load(state, if(mode == :current, do: :all, else: :current))
  end

  def handle(:reload, %State{overlay: {:usage_chart, %{mode: mode}}} = state),
    do: load(state, mode, true)

  def handle(:ignore, %State{} = state), do: {:noreply, state, render?: false}

  @doc "Projects a correlated asynchronous loader result into the open overlay."
  @spec apply_result(State.t(), reference(), mode(), String.t() | nil, term()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def apply_result(
        %State{
          session_id: session_id,
          overlay:
            {:usage_chart, %{request_ref: ref, mode: mode, session_id: session_id} = chart_state}
        } = state,
        ref,
        mode,
        session_id,
        result
      ) do
    chart_state =
      case result do
        {:ok, %UsageTimeline{samples: []} = timeline} ->
          %{chart_state | status: :empty, timeline: timeline, error: nil}

        {:ok, %UsageTimeline{} = timeline} ->
          %{chart_state | status: :loaded, timeline: timeline, error: nil}

        {:error, reason} ->
          %{chart_state | status: :error, timeline: nil, error: reason}

        other ->
          %{chart_state | status: :error, timeline: nil, error: {:invalid_result, other}}
      end

    state = %{state | overlay: {:usage_chart, chart_state}}

    state =
      case result do
        {:ok, %UsageTimeline{} = timeline} ->
          %{
            state
            | usage_timeline_cache:
                Map.put(state.usage_timeline_cache, chart_state.cache_key, timeline)
          }

        _error ->
          state
      end

    {:noreply, state}
  end

  def apply_result(%State{} = state, _ref, _mode, _session_id, _result),
    do: {:noreply, state, render?: false}

  @doc "Invalidates snapshots after durable session usage may have changed."
  @spec invalidate_cache(State.t()) :: State.t()
  def invalidate_cache(%State{} = state), do: %{state | usage_timeline_cache: %{}}

  @doc "Returns the status-row segments for the open chart."
  @spec status_segments(map()) :: [String.t()]
  def status_segments(%{mode: mode, status: status} = chart_state) do
    mode = "Usage · #{mode_label(mode)}"
    status = status_label(status)

    case chart_state[:timeline] do
      %UsageTimeline{skipped_session_count: count} when count > 0 ->
        [mode, status, "#{count} sessions skipped"]

      _timeline ->
        [mode, status]
    end
  end

  @doc "Builds the centered usage popup."
  @spec popup(State.t()) :: Popup.t()
  def popup(%State{overlay: {:usage_chart, chart_state}, size: {width, height}}) do
    %Popup{
      content: content(chart_state, width, height),
      block: Theme.panel_block(popup_title(chart_state.mode, width), :cyan),
      percent_width: 90,
      percent_height: 80
    }
  end

  @doc "Buckets samples into a width-bounded cumulative chronological chart model."
  @spec buckets([Tackle.Session.UsageTimeline.Sample.t()], pos_integer(), keyword()) :: map()
  def buckets(samples, width, opts \\ []) when is_list(samples) and is_integer(width) do
    sorted = Enum.sort_by(samples, &DateTime.to_unix(&1.timestamp))
    sample_first = sorted |> hd() |> then(&DateTime.to_unix(&1.timestamp))
    sample_last = sorted |> List.last() |> then(&DateTime.to_unix(&1.timestamp))
    first_second = datetime_second(Keyword.get(opts, :start_at), sample_first)
    last_second = datetime_second(Keyword.get(opts, :end_at), sample_last)
    max_points = width |> Kernel.-(14) |> div(2) |> max(4) |> min(80)
    interval = interval_for(max(last_second - first_second, 0), max_points)
    bucket_first = div(first_second, interval) * interval
    range_last = div(max(last_second, first_second), interval) * interval
    displayed_last = if range_last == bucket_first, do: bucket_first + interval, else: range_last

    observed =
      sorted
      |> Enum.filter(fn sample ->
        second = DateTime.to_unix(sample.timestamp)
        second >= first_second and second <= last_second
      end)
      |> Enum.group_by(fn sample ->
        div(DateTime.to_unix(sample.timestamp), interval) * interval
      end)
      |> Map.new(fn {second, entries} ->
        total = Enum.sum(Enum.map(entries, &Usage.context_tokens(&1.usage)))
        {second, total}
      end)

    bucket_totals =
      bucket_first
      |> Stream.iterate(&(&1 + interval))
      |> Enum.take_while(&(&1 <= displayed_last))
      |> Enum.map(&{&1, Map.get(observed, &1, 0)})

    {buckets, _total} =
      Enum.map_reduce(bucket_totals, 0, fn {second, tokens}, running_total ->
        running_total = running_total + tokens
        {{second, running_total}, running_total}
      end)

    x_max = (displayed_last - bucket_first) / interval
    peak = buckets |> List.last() |> elem(1)
    y_max = max(peak, 1)

    data =
      Enum.map(buckets, fn {second, total} ->
        {(second - bucket_first) / interval, total * 1.0}
      end)

    %{
      interval_seconds: interval,
      buckets: buckets,
      data: data,
      x_bounds: {0.0, x_max * 1.0},
      y_bounds: {0.0, y_max * 1.0},
      x_labels: time_labels(bucket_first, displayed_last),
      y_labels: ["0", format_count(div(y_max, 2)), format_count(y_max)]
    }
  end

  @doc false
  @spec visible_samples([Tackle.Session.UsageTimeline.Sample.t()], mode(), DateTime.t()) ::
          [Tackle.Session.UsageTimeline.Sample.t()]
  def visible_samples(samples, :current, _now), do: samples

  def visible_samples(samples, :all, now) do
    week_start = UsageTimeline.calendar_week_start(now)

    Enum.filter(samples, fn sample ->
      DateTime.compare(sample.timestamp, week_start) in [:eq, :gt] and
        DateTime.compare(sample.timestamp, now) in [:eq, :lt]
    end)
  end

  defp load(%State{} = state, mode, refresh? \\ false) do
    ref = make_ref()
    session_id = state.session_id
    key = cache_key(mode, session_id)

    chart_state = %{
      mode: mode,
      status: :loading,
      request_ref: ref,
      session_id: session_id,
      cache_key: key,
      timeline: nil,
      error: nil
    }

    case {refresh?, Map.fetch(state.usage_timeline_cache, key)} do
      {false, {:ok, %UsageTimeline{} = timeline}} ->
        status = if timeline.samples == [], do: :empty, else: :loaded
        chart_state = %{chart_state | status: status, timeline: timeline}
        {:noreply, %{state | overlay: {:usage_chart, chart_state}}}

      {_refresh, _cache} ->
        loader = state.usage_timeline_loader

        command =
          Command.async(
            fn -> loader.(mode, session_id) end,
            &{:tui_usage_timeline_result, ref, mode, session_id, &1}
          )

        {:noreply, %{state | overlay: {:usage_chart, chart_state}}, commands: [command]}
    end
  end

  defp content(_chart_state, width, height) when width < 36 or height < 12 do
    %Paragraph{text: "\n Terminal too small for the usage chart.", style: Theme.style(:muted)}
  end

  defp content(%{status: :loading}, _width, _height) do
    %Paragraph{
      text: "\n Loading settled durable usage…",
      style: Theme.style(:muted),
      alignment: :center
    }
  end

  defp content(%{status: :empty, mode: mode}, _width, _height), do: empty_content(mode)

  defp content(%{status: :error, error: reason}, width, _height) do
    detail = reason |> Util.format_reason() |> Util.truncate(max(width - 12, 12))

    %Paragraph{
      text: "\n Could not load usage.\n\n #{detail}\n\n Press R to retry.",
      style: Theme.style(:error),
      alignment: :center
    }
  end

  defp content(%{status: :loaded, timeline: timeline, mode: mode}, width, _height) do
    now = DateTime.utc_now()
    samples = visible_samples(timeline.samples, mode, now)

    if samples == [] do
      empty_content(mode)
    else
      chart(timeline, samples, mode, now, width)
    end
  end

  defp chart(timeline, samples, mode, now, width) do
    range_opts =
      if mode == :all,
        do: [start_at: UsageTimeline.calendar_week_start(now), end_at: now],
        else: []

    model = buckets(samples, max(round(width * 0.9) - 4, 4), range_opts)

    %Chart{
      datasets: [
        %Dataset{
          name: nil,
          data: model.data,
          marker: :braille,
          graph_type: :line,
          style: Theme.style(:accent_soft)
        }
      ],
      x_axis: %Axis{
        title: "UTC · #{interval_label(model.interval_seconds)} buckets",
        bounds: model.x_bounds,
        labels: model.x_labels,
        style: Theme.style(:muted),
        labels_alignment: :center
      },
      y_axis: %Axis{
        title: "cumulative tokens",
        bounds: model.y_bounds,
        labels: model.y_labels,
        style: Theme.style(:muted)
      },
      legend_position: nil,
      block: %Block{
        title: summary(timeline, samples, width),
        borders: [:top],
        border_style: Theme.style(:subtle),
        title_style: %Style{fg: :white}
      }
    }
  end

  defp empty_content(mode) do
    %Paragraph{
      text: "\n No settled token usage in #{empty_scope_label(mode)}.",
      style: Theme.style(:muted),
      alignment: :center
    }
  end

  defp summary(%UsageTimeline{} = timeline, samples, width) do
    usage = Usage.aggregate(Enum.map(samples, & &1.usage))

    segments = [
      "#{length(samples)} generations",
      "total #{format_count(usage.total_tokens || 0)}",
      token_segment("in", usage.input_tokens),
      token_segment("out", usage.output_tokens),
      token_segment("cache", cache_tokens(usage)),
      cost_segment(usage),
      warning_segment(timeline)
    ]

    segments
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> Util.truncate(max(round(width * 0.9) - 6, 1))
  end

  defp token_segment(_label, nil), do: nil
  defp token_segment(label, value), do: "#{label} #{format_count(value)}"

  defp cache_tokens(%Usage{cache_read_tokens: nil, cache_write_tokens: nil}), do: nil

  defp cache_tokens(%Usage{} = usage),
    do: (usage.cache_read_tokens || 0) + (usage.cache_write_tokens || 0)

  defp cost_segment(%Usage{cost: cost, currency: currency} = usage) when is_number(cost) do
    marker = if usage.cost_estimated == true, do: "~", else: ""
    decimals = if abs(cost) < 0.01, do: 4, else: 2
    amount = :erlang.float_to_binary(cost / 1, decimals: decimals)

    case currency do
      "USD" -> "cost #{marker}$#{amount}"
      currency when is_binary(currency) -> "cost #{marker}#{currency} #{amount}"
      nil -> "cost #{marker}#{amount}"
    end
  end

  defp cost_segment(%Usage{}), do: "cost n/a"

  defp warning_segment(%UsageTimeline{skipped_session_count: count}) when count > 0,
    do: "#{count} sessions skipped"

  defp warning_segment(%UsageTimeline{skipped_sample_count: count}) when count > 0,
    do: "#{count} records skipped"

  defp warning_segment(%UsageTimeline{conflicting_sample_count: count}) when count > 0,
    do: "#{count} id conflicts"

  defp warning_segment(_timeline), do: nil

  defp popup_title(mode, width) do
    title = " Usage · #{mode_label(mode)} · Tab/←/→ mode · R reload · Esc close "
    Util.truncate(title, max(round(width * 0.9) - 2, 1))
  end

  defp cache_key(:current, session_id), do: {:current, session_id}

  defp cache_key(:all, _session_id),
    do: {:all, UsageTimeline.calendar_week_start() |> DateTime.to_date()}

  defp status_label(:loading), do: "loading"
  defp status_label(:loaded), do: "loaded"
  defp status_label(:empty), do: "no usage"
  defp status_label(:error), do: "load failed"

  defp mode_label(:current), do: "Current"
  defp mode_label(:all), do: "All sessions · This week"

  defp empty_scope_label(:current), do: "the current session"
  defp empty_scope_label(:all), do: "this UTC calendar week"

  defp datetime_second(%DateTime{} = datetime, _fallback), do: DateTime.to_unix(datetime)
  defp datetime_second(_unset, fallback), do: fallback

  defp interval_for(span, max_points) do
    target = max(ceil_div(max(span, 1), max(max_points - 1, 1)), 1)
    Enum.find(@intervals, target, &(&1 >= target))
  end

  defp ceil_div(left, right), do: div(left + right - 1, right)

  defp time_labels(first_second, last_second) do
    first = DateTime.from_unix!(first_second)
    middle = DateTime.from_unix!(first_second + div(last_second - first_second, 2))
    last = DateTime.from_unix!(last_second)

    format =
      if DateTime.to_date(first) == DateTime.to_date(last), do: "%H:%M", else: "%m-%d %H:%M"

    Enum.map([first, middle, last], &Calendar.strftime(&1, format))
  end

  defp interval_label(seconds) when rem(seconds, 365 * 24 * 60 * 60) == 0,
    do: "#{div(seconds, 365 * 24 * 60 * 60)}y"

  defp interval_label(seconds) when rem(seconds, 24 * 60 * 60) == 0,
    do: "#{div(seconds, 24 * 60 * 60)}d"

  defp interval_label(seconds) when rem(seconds, 60 * 60) == 0,
    do: "#{div(seconds, 60 * 60)}h"

  defp interval_label(seconds) when rem(seconds, 60) == 0, do: "#{div(seconds, 60)}m"
  defp interval_label(seconds), do: "#{seconds}s"

  defp format_count(value) when value < 1_000, do: Integer.to_string(value)
  defp format_count(value) when value < 1_000_000, do: decimal(value / 1_000, "k")
  defp format_count(value), do: decimal(value / 1_000_000, "m")

  defp decimal(value, suffix) do
    decimals = if value < 10 and value != trunc(value), do: 1, else: 0
    :erlang.float_to_binary(value / 1, decimals: decimals) <> suffix
  end
end

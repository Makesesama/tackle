defmodule Tackle.CLI.TUI.WorkflowProgress do
  @moduledoc """
  Bounded, pure projection of one `run_workflow` call's live progress.

  `Tackle.Workflow.Tool` reports a running workflow as `:workflow_progress`
  events (`Tackle.Workflow.Progress` documents each `:kind`). This module folds
  their data into a model that `Tackle.CLI.TUI.WorkflowView` draws as a flow
  chart:

    * `runs` — every visible delegated run by `run_id`: profile, prompt, status
      (`:running`, `:completed`, `:failed`, or `:ended` when the workflow ended
      without awaiting it), the raw outcome status, a locally observed clock,
      and a short `now` line describing the child's current activity;
    * `stages` — runs in the order the workflow started them. A stage is one
      standalone `tackle.spawn` run, several standalone runs that overlapped
      (a run started while the previous stage still had one running), or one
      `tackle.parallel` batch with its items by index, including items that
      never got a run;
    * `logs` — the latest `tackle.log` messages.

  Events come from different processes, so a run's child events may precede
  its start; such a run is created on first sight and placed when its start
  arrives. Only the most recent stages are kept: older ones are evicted with
  their runs and counted in `omitted`. Times are local observations, never
  provider latency.
  """

  @max_stages 200
  @max_logs 20
  @max_now_bytes 200

  @type status :: :running | :completed | :failed | :ended
  @type run :: %{
          required(:run_id) => String.t(),
          required(:status) => status(),
          required(:started_at_ms) => integer(),
          required(:elapsed_ms) => non_neg_integer(),
          optional(:profile) => String.t() | nil,
          optional(:prompt) => String.t() | nil,
          optional(:model) => String.t() | nil,
          optional(:outcome) => atom() | nil,
          optional(:now) => String.t() | nil,
          optional(:placed?) => boolean()
        }
  @type item :: {:run, String.t()} | {:failed, String.t(), String.t() | nil}
  @type stage ::
          %{kind: :runs, runs: [String.t()]}
          | %{
              kind: :parallel,
              id: term(),
              count: non_neg_integer() | nil,
              limit: pos_integer() | nil,
              items: %{pos_integer() => item()}
            }
  @type t :: %{
          runs: %{String.t() => run()},
          stages: [stage()],
          logs: [String.t()],
          omitted: non_neg_integer(),
          settled?: boolean()
        }

  @doc "An empty projection."
  @spec new() :: t()
  def new, do: %{runs: %{}, stages: [], logs: [], omitted: 0, settled?: false}

  @doc "Whether the projection has anything to draw."
  @spec started?(t() | nil) :: boolean()
  def started?(%{runs: runs, stages: stages}), do: map_size(runs) > 0 or stages != []
  def started?(_model), do: false

  @doc """
  Applies one `:workflow_progress` event's data.

  Returns the model unchanged (`===`) when the event changes nothing visible,
  so callers can skip a redraw for repeated child deltas.
  """
  @spec apply(t(), map(), integer()) :: t()
  def apply(model, data, now \\ System.monotonic_time(:millisecond))

  def apply(%{settled?: true} = model, _data, _now), do: model

  def apply(model, data, now) when is_map(data) do
    case value(data, :kind) do
      :run_started -> started(model, data, now)
      :run_event -> run_event(model, data, now)
      :run_finished -> finished(model, data, now)
      :parallel_started -> parallel_started(model, data)
      :item_failed -> item_failed(model, data)
      :log -> log(model, value(data, :message))
      _other -> model
    end
  end

  @doc "Advances running clocks in whole seconds; unchanged when no second ticked."
  @spec refresh(t(), integer()) :: t()
  def refresh(model, now \\ System.monotonic_time(:millisecond)) do
    runs =
      Map.new(model.runs, fn
        {id, %{status: :running} = run} -> {id, %{run | elapsed_ms: elapsed(run, now)}}
        entry -> entry
      end)

    if runs == model.runs, do: model, else: %{model | runs: runs}
  end

  @doc """
  Freezes the projection when the tool call ends.

  Runs the workflow never awaited carry no observed outcome, so they become
  `:ended` rather than a guessed success or failure. Later events are ignored.
  """
  @spec settle(t(), integer()) :: t()
  def settle(model, now \\ System.monotonic_time(:millisecond)) do
    runs =
      Map.new(model.runs, fn
        {id, %{status: :running} = run} ->
          {id, %{run | status: :ended, elapsed_ms: elapsed(run, now)}}

        entry ->
          entry
      end)

    %{model | runs: runs, settled?: true}
  end

  @doc "Run counts by status, for headers and summaries."
  @spec counts(t()) :: %{status() => non_neg_integer(), total: non_neg_integer()}
  def counts(%{runs: runs}) do
    base = %{running: 0, completed: 0, failed: 0, ended: 0, total: map_size(runs)}

    Enum.reduce(Map.values(runs), base, fn run, acc -> Map.update!(acc, run.status, &(&1 + 1)) end)
  end

  # Events ------------------------------------------------------------------------

  defp started(model, data, now) do
    with id when is_binary(id) <- value(data, :run_id) do
      run =
        model.runs
        |> Map.get(id, new_run(id, now))
        |> Map.merge(%{
          profile: value(data, :profile),
          prompt: value(data, :prompt),
          model: value(data, :model)
        })

      if Map.get(run, :placed?) do
        put_run(model, run)
      else
        model
        |> put_run(Map.put(run, :placed?, true))
        |> place(id, value(data, :parallel))
      end
    else
      _invalid -> model
    end
  end

  # Child events only refresh the activity line of a running run; a delta that
  # does not change it leaves the model untouched.
  defp run_event(model, data, now) do
    with id when is_binary(id) <- value(data, :run_id) do
      known? = is_map_key(model.runs, id)
      run = Map.get(model.runs, id) || new_run(id, now, value(data, :profile))
      activity = activity(value(data, :event))

      cond do
        run.status != :running -> model
        known? and (is_nil(activity) or activity == Map.get(run, :now)) -> model
        true -> put_run(model, Map.put(run, :now, activity))
      end
    else
      _invalid -> model
    end
  end

  defp finished(model, data, now) do
    with id when is_binary(id) <- value(data, :run_id) do
      run = Map.get(model.runs, id) || new_run(id, now)

      run = %{
        run
        | status: if(value(data, :ok) == true, do: :completed, else: :failed),
          elapsed_ms: elapsed(run, now)
      }

      run =
        run
        |> Map.put(:outcome, value(data, :status))
        |> Map.put(:now, nil)
        |> Map.update(:profile, value(data, :profile), &(&1 || value(data, :profile)))

      put_run(model, run)
    else
      _invalid -> model
    end
  end

  defp parallel_started(model, data) do
    stage = %{
      kind: :parallel,
      id: value(data, :id),
      count: value(data, :count),
      limit: value(data, :limit),
      items: %{}
    }

    push_stage(model, stage)
  end

  defp item_failed(model, data) do
    case value(data, :parallel) do
      %{id: id, index: index} ->
        item = {:failed, to_string(value(data, :status) || "failed"), value(data, :text)}
        update_parallel(model, id, &put_in(&1, [:items, index], item))

      _invalid ->
        model
    end
  end

  defp log(model, message) when is_binary(message),
    do: %{model | logs: Enum.take(model.logs ++ [message], -@max_logs)}

  defp log(model, _message), do: model

  # Stages ------------------------------------------------------------------------

  defp place(model, id, %{id: batch, index: index}),
    do: update_parallel(model, batch, &put_in(&1, [:items, index], {:run, id}))

  # A standalone run joins the previous standalone stage while that stage still
  # has a run in flight: the script spawned it before awaiting the others.
  defp place(model, id, _parallel) do
    case List.last(model.stages) do
      %{kind: :runs, runs: ids} = stage ->
        if Enum.any?(ids, &match?(%{status: :running}, model.runs[&1])),
          do: %{model | stages: List.replace_at(model.stages, -1, %{stage | runs: ids ++ [id]})},
          else: push_stage(model, %{kind: :runs, runs: [id]})

      _other ->
        push_stage(model, %{kind: :runs, runs: [id]})
    end
  end

  # A batch whose start was not seen (or was evicted) is recreated rather than
  # dropping its items.
  defp update_parallel(model, batch, fun) do
    case Enum.find_index(model.stages, &match?(%{kind: :parallel, id: ^batch}, &1)) do
      nil ->
        push_stage(model, fun.(%{kind: :parallel, id: batch, count: nil, limit: nil, items: %{}}))

      index ->
        %{model | stages: List.update_at(model.stages, index, fun)}
    end
  end

  defp push_stage(model, stage) do
    model = %{model | stages: model.stages ++ [stage]}

    if length(model.stages) > @max_stages, do: evict_oldest(model), else: model
  end

  defp evict_oldest(%{stages: [oldest | rest]} = model) do
    ids = stage_run_ids(oldest)
    %{model | stages: rest, runs: Map.drop(model.runs, ids), omitted: model.omitted + 1}
  end

  defp stage_run_ids(%{kind: :runs, runs: ids}), do: ids
  defp stage_run_ids(%{items: items}), do: for({_index, {:run, id}} <- items, do: id)

  # Runs --------------------------------------------------------------------------

  defp new_run(id, now, profile \\ nil),
    do: %{run_id: id, status: :running, started_at_ms: now, elapsed_ms: 0, profile: profile}

  defp put_run(model, run), do: %{model | runs: Map.put(model.runs, run.run_id, run)}

  defp elapsed(%{started_at_ms: started}, now) when is_integer(started),
    do: div(max(now - started, 0), 1_000) * 1_000

  defp elapsed(run, _now), do: Map.get(run, :elapsed_ms, 0)

  defp activity(%{type: :tool_start, data: data}) do
    name = value(data, :name) || value(data, :tool_name) || "tool"
    args = value(data, :arguments)
    target = if is_map(args), do: value(args, :path) || value(args, :command)

    label = if is_binary(target), do: "#{name} #{first_line(target)}", else: to_string(name)
    bound(label)
  end

  defp activity(%{type: type}) when type in [:message_start, :message_delta], do: "responding"
  defp activity(%{type: :tool_error}), do: "tool failed"
  defp activity(_event), do: nil

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()

  defp bound(text) when byte_size(text) <= @max_now_bytes, do: text
  defp bound(text), do: String.slice(text, 0, @max_now_bytes)

  defp value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp value(_other, _key), do: nil
end

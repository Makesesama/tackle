defmodule Tackle.Workflow.Meter do
  @moduledoc """
  Token and tool-call accounting for one workflow's delegated runs.

  The meter turns the events a delegated run's agent already emits into facts a
  workflow can branch on without trusting the run's text:

    * every settled model call (`:step_end`) adds its `total_tokens` to the run
      and to the workflow total, so tokens are counted while a run is still
      working, and also for runs that fail, time out, or are never awaited;
    * every `:tool_end` event counts one tool call, and every `:tool_error`
      event counts one failed tool call.

  A streaming model call reports `:usage` while it streams and again when it
  settles, so `:usage` is not added up. It is kept as the call's pending usage,
  which `:step_end` counts only when it carries no usage of its own. A call cut
  off before it settles is not counted.

  The workflow total backs the optional token budget: once it reaches the
  budget, the workflow API refuses to start new runs. Runs already in flight
  are not interrupted, so a workflow can overshoot its budget by what those
  runs spend.

  `tackle.classify` adds the tokens of each classification by a remote
  decision model to the workflow total with `add_usage/2`. A local decision
  model (`Tackle.Lib.Decision.local?/0`) spends no budgeted tokens and is not
  counted. Only reported usage is counted: a classification whose adapter
  reports no usage, or that fails before the model answers, adds nothing.

  Only the runs a workflow starts are metered. Delegation inside those runs
  reports to its own parent, not to the workflow, so it is not counted.

  Facts are complete when a run's outcome is collected only if its backend
  delivers the run's events before its terminal result, as `Tackle.Session`
  does.

  The counters live in a public ETS table owned by the process that evaluates
  the workflow, because a run's events are delivered in that run's runtime
  request process. The table goes away with the workflow; an event that
  arrives afterwards is dropped, never raised into the runtime.
  """

  alias Tackle.Lib.Event
  alias Tackle.Lib.Usage

  @enforce_keys [:table]
  defstruct [:table, :token_budget]

  @type t :: %__MODULE__{table: :ets.tid(), token_budget: pos_integer() | nil}

  @total :tokens

  @doc """
  Creates a meter owned by the calling process, with an optional token budget.
  """
  @spec new(pos_integer() | nil) :: t()
  def new(token_budget \\ nil)
      when is_nil(token_budget) or (is_integer(token_budget) and token_budget > 0) do
    table = :ets.new(__MODULE__, [:set, :public, write_concurrency: true])
    %__MODULE__{table: table, token_budget: token_budget}
  end

  @doc """
  Records one event from the run `run_id`. Events that carry no accountable
  fact are ignored.

  Never raises: the event comes from the run's runtime request process, which a
  malformed event must not take down.
  """
  @spec record(t(), String.t(), Event.t() | term()) :: :ok
  def record(%__MODULE__{} = meter, run_id, event) do
    do_record(meter, run_id, event)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp do_record(%__MODULE__{table: table}, run_id, %Event{type: :usage, data: data}) do
    :ets.insert(table, {{run_id, :pending}, tokens(data)})
  end

  defp do_record(%__MODULE__{table: table} = meter, run_id, %Event{type: :step_end, data: data}) do
    count =
      case tokens(data) do
        0 -> read(meter, {run_id, :pending})
        count -> count
      end

    :ets.delete(table, {run_id, :pending})
    increment(meter, {run_id, :tokens}, count)
    increment(meter, @total, count)
  end

  defp do_record(meter, run_id, %Event{type: :tool_end}),
    do: increment(meter, {run_id, :tool_calls}, 1)

  defp do_record(meter, run_id, %Event{type: :tool_error}) do
    increment(meter, {run_id, :tool_calls}, 1)
    increment(meter, {run_id, :failed_tool_calls}, 1)
  end

  defp do_record(_meter, _run_id, _event), do: :ok

  @doc """
  Adds tokens spent outside any run, such as a classification, to the workflow
  total and returns how many were added. Usage without a positive total adds
  nothing.
  """
  @spec add_usage(t(), Usage.t() | map() | nil) :: non_neg_integer()
  def add_usage(%__MODULE__{} = meter, usage) do
    count = tokens(%{usage: usage})
    increment(meter, @total, count)
    count
  end

  @doc "Total tokens the workflow's runs have reported so far."
  @spec tokens_used(t()) :: non_neg_integer()
  def tokens_used(%__MODULE__{} = meter), do: read(meter, @total)

  @doc "Whether the workflow has used up its token budget. Always false without one."
  @spec exhausted?(t()) :: boolean()
  def exhausted?(%__MODULE__{token_budget: nil}), do: false
  def exhausted?(%__MODULE__{token_budget: budget} = meter), do: tokens_used(meter) >= budget

  @doc """
  The workflow's budget as a Lua-facing table: `used`, and `limit` and
  `remaining` when the workflow has a budget.
  """
  @spec budget(t()) :: %{String.t() => non_neg_integer()}
  def budget(%__MODULE__{token_budget: nil} = meter), do: %{"used" => tokens_used(meter)}

  def budget(%__MODULE__{token_budget: budget} = meter) do
    used = tokens_used(meter)
    %{"used" => used, "limit" => budget, "remaining" => max(budget - used, 0)}
  end

  @doc "The facts recorded for one run, as a Lua-facing table."
  @spec run_facts(t(), String.t()) :: %{String.t() => non_neg_integer()}
  def run_facts(%__MODULE__{} = meter, run_id) do
    %{
      "tokens" => read(meter, {run_id, :tokens}),
      "tool_calls" => read(meter, {run_id, :tool_calls}),
      "failed_tool_calls" => read(meter, {run_id, :failed_tool_calls})
    }
  end

  # `Usage.normalize/1` derives `total_tokens` from the buckets a provider
  # reported when it did not report a total itself.
  defp tokens(%{usage: usage}) when is_map(usage) do
    case Usage.normalize(usage) do
      %Usage{total_tokens: total} when is_integer(total) and total > 0 -> total
      _other -> 0
    end
  end

  defp tokens(_data), do: 0

  defp increment(_meter, _key, 0), do: :ok

  defp increment(%__MODULE__{table: table}, key, count) do
    :ets.update_counter(table, key, {2, count}, {key, 0})
    :ok
  end

  defp read(%__MODULE__{table: table}, key) do
    case :ets.lookup(table, key) do
      [{^key, count}] -> count
      [] -> 0
    end
  end
end

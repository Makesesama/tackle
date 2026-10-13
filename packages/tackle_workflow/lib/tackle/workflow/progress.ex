defmodule Tackle.Workflow.Progress do
  @moduledoc """
  Observable progress of one running workflow.

  A host that passes `:on_event` to `Tackle.Workflow.run/3` receives one plain
  map per progress event, so a frontend can show which delegated runs a
  workflow started, what they are doing, and how they settled while the
  workflow is still running. Every event carries a `:type`:

    * `%{type: :run_started, run_id: id, profile: name, prompt: text, model: ref,
      parallel: nil | %{id: id, index: i}}` — a delegated run was admitted, by
      `tackle.spawn` (`parallel: nil`) or as item `i` of a `tackle.parallel`
      batch;
    * `%{type: :run_event, run_id: id, profile: name, event: Tackle.Lib.Event.t()}`
      — one event from that run's child agent, such as a message delta or a tool
      call;
    * `%{type: :run_finished, run_id: id, profile: name | nil, status: status,
      ok: boolean}` — the workflow observed the run's outcome (`tackle.await`,
      or settlement inside a `tackle.parallel` batch). `tackle.await` holds only
      the run handle, so its `profile` is `nil`; match it to the run's
      `:run_started` by `:run_id`. A run the script never awaits reports no
      settlement: it ends with the workflow;
    * `%{type: :parallel_started, id: id, count: n, limit: l}` and
      `%{type: :parallel_finished, id: id}` — the bounds of one
      `tackle.parallel` batch;
    * `%{type: :item_failed, parallel: %{id: id, index: i}, status: status,
      text: text}` — a batch item ended without a run (`"callback_error"`,
      `"spawn_error"`, `"capacity"`, or `"unavailable"`);
    * `%{type: :classify_started, id: id, label: text | nil, model: ref, local: boolean,
      questions: [%{name: name, type: :choice | :noul | :score, options: [text] | nil}]}`
      — a `tackle.classify` call is asking its decision model. `options` are
      the choice names (sorted) or the score levels (lowest first), `nil` for
      `noul`; `label` is the script's `label` option;
    * `%{type: :classify_finished, id: id, label: text | nil, ok: boolean,
      status: :ok | :error | :cancelled, tokens: n, answers: %{name => answer} | nil,
      text: text | nil}` — the call settled. `answers` holds the same answer
      tables the script receives (string keys, see `Tackle.Workflow.Classify`),
      probabilities included; `text` is the failure reason. A call cut short
      by the workflow's cancellation reports no settlement;
    * `%{type: :log, message: text}` — a `tackle.log/1` message.

  Events are emitted from whichever process observed them — the workflow
  worker for its own calls, the runtime for child events — so a run's
  `:run_event`s may arrive before its `:run_started`. Consumers should key runs
  by `:run_id` and tolerate either order. A classification runs in the
  workflow worker, so its `:classify_started` always precedes its
  `:classify_finished`; match them by `:id`. A classification that raises
  (bad arguments, an unknown model, a spent budget) reports nothing.

  Progress is presentation, never control: a callback that raises or exits is
  logged and ignored, so an observer can never fail the workflow. Callbacks run
  synchronously in the emitting process, so they should be quick — sending a
  message, as `Tackle.Workflow.Tool` does, is the intended shape.
  """

  alias Tackle.Lib.Decision.{Question, Selection}

  require Logger

  @typedoc "One progress event; see the module documentation for each shape."
  @type event :: %{required(:type) => atom(), optional(atom()) => term()}

  @typedoc "A host progress callback, or `nil` when nobody observes."
  @type callback :: (event() -> any()) | nil

  @doc "Delivers one event to `callback`, isolating the workflow from its failures."
  @spec emit(callback(), event()) :: :ok
  def emit(nil, _event), do: :ok

  def emit(callback, %{type: _type} = event) when is_function(callback, 1) do
    callback.(event)
    :ok
  rescue
    error ->
      Logger.warning("workflow progress callback failed: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("workflow progress callback failed: #{inspect({kind, reason})}")
      :ok
  end

  @doc """
  Runtime request options that stream a run's child events as `:run_event`s.

  Returns `[]` when nobody observes, so an unobserved workflow forwards no run
  events. `Tackle.Workflow.API` still meters every run's events.
  """
  @spec request_opts(callback(), String.t()) :: keyword()
  def request_opts(nil, _profile), do: []

  def request_opts(callback, profile) when is_function(callback, 1) do
    [
      event_callback: fn run_ref, child_event ->
        emit(callback, %{
          type: :run_event,
          run_id: run_ref.run_id,
          profile: profile,
          event: child_event
        })
      end
    ]
  end

  @doc "Builds a `:run_started` event for an admitted run."
  @spec run_started(map(), String.t(), String.t(), map() | nil) :: event()
  def run_started(run_ref, profile, prompt, parallel \\ nil) do
    %{
      type: :run_started,
      run_id: run_ref.run_id,
      profile: profile,
      prompt: prompt,
      model: Map.get(run_ref, :model_ref),
      parallel: parallel
    }
  end

  @doc "Builds a `:run_finished` event from an observed outcome status."
  @spec run_finished(map(), String.t() | nil, atom(), boolean()) :: event()
  def run_finished(run_ref, profile, status, ok?) do
    %{type: :run_finished, run_id: run_ref.run_id, profile: profile, status: status, ok: ok?}
  end

  @doc "A fresh identifier for one `tackle.parallel` batch."
  @spec parallel_id() :: pos_integer()
  def parallel_id, do: System.unique_integer([:positive, :monotonic])

  @doc "A fresh identifier for one `tackle.classify` call."
  @spec classify_id() :: pos_integer()
  def classify_id, do: System.unique_integer([:positive, :monotonic])

  @doc "Builds a `:classify_started` event for a classification about to be asked."
  @spec classify_started(pos_integer(), String.t() | nil, Selection.t(), [Question.t()]) ::
          event()
  def classify_started(id, label, %Selection{} = selection, questions) do
    %{
      type: :classify_started,
      id: id,
      label: label,
      model: selection.ref,
      local: selection.local,
      questions: Enum.map(questions, &question/1)
    }
  end

  @doc "Builds a `:classify_finished` event from the table returned to the script."
  @spec classify_finished(pos_integer(), String.t() | nil, map()) :: event()
  def classify_finished(id, label, %{"ok" => ok?, "status" => status} = table) do
    %{
      type: :classify_finished,
      id: id,
      label: label,
      ok: ok?,
      status: classify_status(status),
      tokens: Map.get(table, "tokens", 0),
      answers: Map.get(table, "answers"),
      text: Map.get(table, "text")
    }
  end

  defp question(%Question{name: name, type: type, criteria: criteria}),
    do: %{name: name, type: type, options: options(type, criteria)}

  defp options(:choice, criteria) when is_map(criteria), do: criteria |> Map.keys() |> Enum.sort()
  defp options(:score, levels) when is_list(levels), do: levels
  defp options(_type, _criteria), do: nil

  defp classify_status("ok"), do: :ok
  defp classify_status("cancelled"), do: :cancelled
  defp classify_status(_error), do: :error
end

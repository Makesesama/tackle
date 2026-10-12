defmodule Tackle.CLI.TUI.Review do
  @moduledoc """
  `/review`: code review from the shell, with a findings overlay.

  `/review [RANGE | --staged]` loads the change from Git and runs
  `Tackle.Review.run/2` in a background command, so the shell stays
  responsive. The review's detector and verifier runs are delegated from
  the root agent with the scope's own `review-detector` and
  `review-verifier` profiles, so they appear in `/tasks` (F7) like any
  other delegated run. Progress events are projected by
  `Tackle.CLI.TUI.ReviewProgress` while the overlay
  (`Tackle.CLI.TUI.ReviewView`) shows them; once the review finishes the
  overlay lists the findings, blocking first, with a detail pane for the
  selected one.

  In the overlay:

    * `u` / `n` mark the selected finding useful / not useful;
    * `d` dismisses it, so later reviews do not report it again;
    * `f` sends it to the chat agent as a prompt to fix it, `F` sends every
      blocking finding that was not dismissed;
    * `r` re-reviews the files whose diff changed since the review and
      replaces their findings, keeping the others; it needs a finished
      review, since a cancelled or failed one never reviewed its change;
    * `x` cancels a running review; `Esc` closes the overlay, and a running
      review continues in the background.

  Every feedback action (`u`, `n`, `d`, and the fixes, recorded as `fixed`)
  is appended to the repository's `Tackle.Review.History`, and every review
  run is recorded there by `Tackle.Review.run/2`. History is an aid: when it
  cannot be opened or written the review still works and the overlay says
  feedback was not saved.

  `/findings` reopens the overlay after it was closed, for example after a
  fix turn, so `r` can check the fix.

  The review lives in `State.review`, independent of the overlay; starting
  a new or resumed session discards it (`discard/1`) and cancels a running
  one. Messages from the background command carry the review's reference,
  so a superseded review cannot update the current one.
  """

  alias ExRatatui.Command
  alias Tackle.AgentScope.Coordinator
  alias Tackle.CLI.Output.Review, as: ReviewOutput
  alias Tackle.CLI.TUI.{Composer, ReviewProgress, State}
  alias Tackle.CLI.Widgets.Input
  alias Tackle.Lib.Cancellation
  alias Tackle.Review.{Change, Detector, Finding, History, Result, Verifier}
  alias Tackle.Runtime.Registry

  @usage "Usage: /review [RANGE | --staged]"

  @typedoc """
  Where the review is:

    * `:loading` - the change is being loaded from Git;
    * `:running` - the review pipeline runs;
    * `:cancelling` - cancellation was requested;
    * `:done` - findings are shown (also after a failed or cancelled
      re-review, which keeps the previous findings);
    * `:failed` / `:cancelled` - a full review ended without findings.
  """
  @type status :: :loading | :running | :cancelling | :done | :failed | :cancelled

  @typedoc "What `/review` reviews: a revision range, the index, or the branch (both unset)."
  @type target :: %{range: String.t() | nil, staged: boolean()}

  @typedoc """
  A `/review` session in the shell.

    * `ref` correlates background messages with the current run;
    * `mode` is `:full` for `/review` and `:rereview` for `r`;
    * `change` is the reviewed change and `next_change` the one a running
      re-review loaded; `touched` the paths it re-reviews;
    * `blocking` / `optional` are the shown findings and `outcomes` the
      latest feedback per fingerprint;
    * `selected` indexes `findings/1` and `scroll` the detail pane.
  """
  @type t :: %__MODULE__{
          ref: reference() | nil,
          status: status(),
          mode: :full | :rereview,
          target: target(),
          signal: Cancellation.signal() | nil,
          change: Change.t() | nil,
          next_change: Change.t() | nil,
          touched: [String.t()] | nil,
          history: History.t() | nil,
          progress: ReviewProgress.t(),
          blocking: [Finding.t()],
          optional: [Finding.t()],
          summary: Result.summary() | nil,
          outcomes: %{optional(String.t()) => History.outcome()},
          notes: [String.t()],
          error: String.t() | nil,
          selected: non_neg_integer(),
          scroll: non_neg_integer()
        }

  defstruct ref: nil,
            status: :loading,
            mode: :full,
            target: %{range: nil, staged: false},
            signal: nil,
            change: nil,
            next_change: nil,
            touched: nil,
            history: nil,
            progress: %ReviewProgress{},
            blocking: [],
            optional: [],
            summary: nil,
            outcomes: %{},
            notes: [],
            error: nil,
            selected: 0,
            scroll: 0

  @typedoc "A message the background command sends to the shell."
  @type message ::
          {:loaded, Change.t(), History.t() | nil, [String.t()] | nil, [String.t()]}
          | {:event, Tackle.Review.event()}
          | {:finished, {:ok, Result.t() | :unchanged} | {:error, term()}}

  @typedoc """
  Everything the background command needs, captured from the shell state
  when the review starts: where and how to load the change, the requester
  and scope to delegate from, the cancellation signal, and, for a
  re-review, the previously reviewed change.
  """
  @type request :: %{
          cwd: Path.t() | nil,
          executor: Tackle.Executor.t(),
          env: map() | nil,
          range: String.t() | nil,
          staged: boolean(),
          requester: term(),
          scope_ref: term(),
          signal: Cancellation.signal(),
          previous: Change.t() | nil
        }

  @typedoc "An intent from `Tackle.CLI.Keybinds.review/1`."
  @type intent ::
          :close
          | :previous
          | :next
          | {:scroll, :up | :down}
          | {:outcome, :useful | :not_useful | :dismissed}
          | :fix
          | :fix_blocking
          | :rereview
          | :cancel
          | :ignore

  # -- commands ---------------------------------------------------------------

  @doc """
  Starts a review for `/review ARGS` and opens the overlay.

  `ARGS` is empty (the branch against the default branch), a revision
  range, or `--staged`. A review that is still running is reopened instead
  of replaced. Invalid arguments leave the shell untouched apart from a
  usage notice.
  """
  @spec start(State.t(), String.t()) :: {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def start(%State{review: %__MODULE__{status: status}} = state, _args)
      when status in [:loading, :running, :cancelling] do
    {:noreply, %{state | overlay: {:review, %{}}, notice: "A review is already running"}}
  end

  def start(%State{} = state, args) when is_binary(args) do
    case parse_args(args) do
      {:ok, target} ->
        discard(state.review)
        launch(state, %__MODULE__{target: target}, nil)

      {:error, message} ->
        {:noreply, %{state | notice: message}}
    end
  end

  @doc """
  Reopens the overlay of the last review (`/findings`).

  Without a review in this session it only says how to start one.
  """
  @spec reopen(State.t()) :: {:noreply, State.t()}
  def reopen(%State{review: %__MODULE__{}} = state),
    do: {:noreply, %{state | overlay: {:review, %{}}}}

  def reopen(%State{} = state),
    do: {:noreply, %{state | notice: "No review in this session · /review starts one"}}

  @doc """
  Parses `/review` arguments into a target.

      iex> Tackle.CLI.TUI.Review.parse_args("")
      {:ok, %{range: nil, staged: false}}

      iex> Tackle.CLI.TUI.Review.parse_args("main..HEAD")
      {:ok, %{range: "main..HEAD", staged: false}}

      iex> Tackle.CLI.TUI.Review.parse_args("--staged")
      {:ok, %{range: nil, staged: true}}
  """
  @spec parse_args(String.t()) :: {:ok, target()} | {:error, String.t()}
  def parse_args(args) when is_binary(args) do
    case String.split(args) do
      [] -> {:ok, %{range: nil, staged: false}}
      ["--staged"] -> {:ok, %{range: nil, staged: true}}
      ["-" <> _option] -> {:error, @usage}
      [range] -> {:ok, %{range: range, staged: false}}
      _many -> {:error, @usage}
    end
  end

  @doc """
  Discards a review, cancelling it when it still runs, and returns `nil`.

  Used when the shell adopts another session: the review belonged to the
  previous one.
  """
  @spec discard(t() | nil) :: nil
  def discard(%__MODULE__{signal: signal, status: status})
      when status in [:loading, :running, :cancelling] and not is_nil(signal) do
    Cancellation.cancel(signal)
    nil
  end

  def discard(_review), do: nil

  @doc "Whether a review is loading or running."
  @spec running?(t() | nil) :: boolean()
  def running?(%__MODULE__{status: status}), do: status in [:loading, :running, :cancelling]
  def running?(_review), do: false

  @doc """
  Whether `r` can re-review: only after a review finished, so the
  previously reviewed change actually produced findings. A cancelled or
  failed review never reviewed its change; it needs a new `/review`.
  """
  @spec rereviewable?(t() | nil) :: boolean()
  def rereviewable?(%__MODULE__{status: :done, change: %Change{}}), do: true
  def rereviewable?(_review), do: false

  @doc "The shown findings, blocking first; `selected` indexes this list."
  @spec findings(t()) :: [Finding.t()]
  def findings(%__MODULE__{blocking: blocking, optional: optional}), do: blocking ++ optional

  @doc "The selected finding, or `nil`."
  @spec selected(t()) :: Finding.t() | nil
  def selected(%__MODULE__{} = review), do: Enum.at(findings(review), review.selected)

  defp launch(%State{} = state, %__MODULE__{} = review, previous) do
    ref = make_ref()
    signal = Cancellation.new_signal()
    shell = self()

    request = %{
      cwd: state.cwd,
      executor: state.executor,
      env: state.env,
      range: review.target.range,
      staged: review.target.staged,
      requester: state.agent_ref,
      scope_ref: state.scope_ref,
      signal: signal,
      previous: previous
    }

    command =
      Command.async(
        fn -> execute(request, &send(shell, {:tui_review, ref, &1})) end,
        &{:tui_review, ref, {:finished, &1}}
      )

    review = %{
      review
      | ref: ref,
        signal: signal,
        status: :loading,
        progress: ReviewProgress.new(),
        next_change: nil,
        touched: nil,
        error: nil
    }

    {:noreply, %{state | review: review, overlay: {:review, %{}}}, commands: [command]}
  end

  # -- background command -----------------------------------------------------

  @doc """
  Runs one review for `request`; called in the background command.

  Loads the change, opens the repository's history, and reports
  `{:loaded, change, history, paths, notes}` through `notify` before any
  model call. For a re-review (`request.previous` set), `paths` are the
  files whose diff differs from the previous change and only those are
  reviewed; nothing touched returns `{:ok, :unchanged}` without a review.
  A full review reports `nil` paths. Review events follow as
  `{:event, event}`.

  Returns the review's result, or `{:error, {:change, reason}}` when the
  change cannot be loaded and the review's own error otherwise.
  """
  @spec execute(request(), (message() -> any())) ::
          {:ok, Result.t() | :unchanged} | {:error, term()}
  def execute(request, notify) when is_map(request) and is_function(notify, 1) do
    with {:ok, change} <- load_change(request) do
      {history, notes} = open_history(change, request.env)
      paths = if request.previous, do: touched_paths(request.previous, change)
      notify.({:loaded, change, history, paths, notes})

      case paths do
        [] ->
          {:ok, :unchanged}

        paths ->
          opts = [
            requester: request.requester,
            profiles: profiles(request.scope_ref),
            history: history,
            cancellation: request.signal,
            on_event: &notify.({:event, &1})
          ]

          Tackle.Review.run(restrict(change, paths), opts)
      end
    end
  end

  @doc """
  Paths of `current` whose diff differs from `previous`, in diff order:
  files changed since the review and files new to the change. Files that
  left the change are not listed; their findings are obsolete.
  """
  @spec touched_paths(Change.t(), Change.t()) :: [String.t()]
  def touched_paths(%Change{} = previous, %Change{} = current) do
    before = Map.new(previous.diff.files, &{&1.path, &1})
    for file <- current.diff.files, Map.get(before, file.path) != file, do: file.path
  end

  defp load_change(request) do
    opts = [
      cwd: request.cwd,
      executor: request.executor,
      staged: request.staged,
      range: request.range
    ]

    case Change.load(opts) do
      {:ok, change} -> {:ok, change}
      {:error, reason} -> {:error, {:change, reason}}
    end
  end

  defp open_history(change, env) do
    opts = if is_map(env), do: [env: env], else: []

    case History.open(change.root, opts) do
      {:ok, history} ->
        {history, []}

      {:error, reason} ->
        {nil, ["Review history is unavailable: #{History.format_error(reason)}"]}
    end
  end

  defp restrict(change, nil), do: change

  defp restrict(change, paths) do
    keep = MapSet.new(paths)
    only = fn diff -> %{diff | files: Enum.filter(diff.files, &MapSet.member?(keep, &1.path))} end
    %{change | diff: only.(change.diff), context_diff: only.(change.context_diff)}
  end

  # The stage profiles come from the shell's own scope, resolved when the
  # review starts, as `Tackle.Tools.Review` resolves them for the agent.
  defp profiles(scope_ref) do
    Map.new([Detector.profile(), Verifier.profile()], fn name ->
      {name, fn -> resolve_profile(scope_ref, name) end}
    end)
  end

  defp resolve_profile(scope_ref, name) do
    case Registry.coordinator(scope_ref) do
      {:ok, coordinator} -> Coordinator.resolve_profile(coordinator, name)
      {:error, :not_found} -> {:error, :scope_not_found}
    end
  end

  # -- background messages ----------------------------------------------------

  @doc """
  Applies a message from the background command with reference `ref`.

  Messages of any other review are ignored without a redraw.
  """
  @spec apply(State.t(), reference(), message()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def apply(%State{review: %__MODULE__{ref: ref} = review} = state, ref, message),
    do: apply_message(state, review, message)

  def apply(%State{} = state, _ref, _message), do: {:noreply, state, render?: false}

  defp apply_message(state, review, {:loaded, change, history, paths, notes}) do
    review = %{review | history: history, touched: paths, status: running_status(review)}

    review =
      case review.mode do
        :full -> %{review | change: change, notes: notes}
        :rereview -> %{review | next_change: change, notes: notes}
      end

    {:noreply, %{state | review: review}}
  end

  defp apply_message(state, review, {:event, event}) do
    progress = ReviewProgress.apply(review.progress, event)

    if progress === review.progress,
      do: {:noreply, state, render?: false},
      else: {:noreply, %{state | review: %{review | progress: progress}}}
  end

  defp apply_message(state, review, {:finished, result}) do
    if review.signal, do: Cancellation.delete(review.signal)
    {review, notice} = finish(%{review | signal: nil}, result)
    state = %{state | review: review}

    notice =
      case state.overlay do
        {:review, _view} -> notice
        _other -> notice <> " · /findings opens it"
      end

    {:noreply, %{state | notice: notice}}
  end

  defp apply_message(state, _review, _message), do: {:noreply, state, render?: false}

  defp running_status(%__MODULE__{status: :cancelling}), do: :cancelling
  defp running_status(%__MODULE__{}), do: :running

  defp finish(%__MODULE__{mode: :full} = review, {:ok, %Result{} = result}) do
    review = %{
      review
      | status: :done,
        blocking: result.blocking,
        optional: result.optional,
        summary: result.summary,
        notes: review.notes ++ result_notes(result),
        selected: 0,
        scroll: 0
    }

    {review, "Review finished: #{counts(review)}"}
  end

  defp finish(%__MODULE__{mode: :rereview} = review, {:ok, %Result{} = result}) do
    change = review.next_change
    present = MapSet.new(change.diff.files, & &1.path)
    touched = MapSet.new(review.touched || [])

    keep? = fn finding ->
      path = finding.location.path
      MapSet.member?(present, path) and not MapSet.member?(touched, path)
    end

    review = %{
      review
      | status: :done,
        change: change,
        next_change: nil,
        blocking: merge(review.blocking, result.blocking, keep?),
        optional: merge(review.optional, result.optional, keep?),
        summary: result.summary,
        notes: review.notes ++ result_notes(result)
    }

    files = length(review.touched)
    noun = if files == 1, do: "file", else: "files"
    {clamp(review), "Re-reviewed #{files} changed #{noun}: #{counts(review)}"}
  end

  defp finish(%__MODULE__{} = review, {:ok, :unchanged}) do
    {%{review | status: :done, next_change: nil}, "Nothing changed since the review"}
  end

  defp finish(%__MODULE__{mode: :rereview} = review, {:error, reason}) do
    review = %{review | status: :done, next_change: nil}

    case reason do
      :cancelled -> {review, "Re-review cancelled"}
      reason -> {review, "Re-review failed: #{ReviewOutput.format_error(reason)}"}
    end
  end

  defp finish(%__MODULE__{} = review, {:error, :cancelled}),
    do: {%{review | status: :cancelled, error: "The review was cancelled."}, "Review cancelled"}

  defp finish(%__MODULE__{} = review, {:error, reason}) do
    message = describe_failure(reason)
    {%{review | status: :failed, error: message}, "Review failed: #{message}"}
  end

  defp describe_failure({:exception, message}) when is_binary(message), do: message
  defp describe_failure(reason), do: ReviewOutput.format_error(reason)

  defp merge(old, new, keep?),
    do: old |> Enum.filter(keep?) |> Kernel.++(new) |> Enum.uniq_by(& &1.fingerprint)

  defp counts(review),
    do: "#{length(review.blocking)} blocking, #{length(review.optional)} optional"

  defp result_notes(%Result{summary: summary, dropped: dropped}) do
    known = Enum.count(dropped, &(&1.reason == :known))

    Enum.map(summary.failed_units, fn %{unit: unit, reason: reason} ->
      "Unit #{unit} was not reviewed: #{Tackle.Review.Delegation.format_error(reason)}"
    end) ++
      if(known > 0, do: ["#{known} dismissed finding(s) not reported again"], else: []) ++
      summary.warnings
  end

  # -- overlay intents --------------------------------------------------------

  @doc "Handles one resolved overlay intent (see `Tackle.CLI.Keybinds.review/1`)."
  @spec handle(intent(), State.t()) :: {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def handle(:ignore, state), do: {:noreply, state, render?: false}

  def handle(:close, %State{review: review} = state) do
    notice = if running?(review), do: "The review continues · /findings reopens it"
    {:noreply, %{state | overlay: nil, notice: notice}}
  end

  def handle(_intent, %State{review: nil} = state), do: {:noreply, %{state | overlay: nil}}

  def handle(direction, %State{review: review} = state) when direction in [:previous, :next] do
    count = length(findings(review))
    delta = if direction == :previous, do: -1, else: 1
    selected = if count == 0, do: 0, else: Integer.mod(review.selected + delta, count)
    {:noreply, %{state | review: %{review | selected: selected, scroll: 0}}}
  end

  def handle({:scroll, direction}, %State{review: review} = state) do
    scroll = if direction == :up, do: max(review.scroll - 1, 0), else: review.scroll + 1
    {:noreply, %{state | review: %{review | scroll: scroll}}}
  end

  def handle({:outcome, outcome}, %State{review: review} = state) do
    case selected(review) do
      nil ->
        {:noreply, %{state | notice: "No finding selected"}}

      finding ->
        {review, saved} = record(review, [finding], outcome)
        {:noreply, %{state | review: review, notice: outcome_notice(outcome) <> saved}}
    end
  end

  def handle(:fix, %State{review: review} = state) do
    case selected(review) do
      nil -> {:noreply, %{state | notice: "No finding selected"}}
      finding -> fix(state, [finding])
    end
  end

  def handle(:fix_blocking, %State{review: review} = state) do
    case Enum.reject(review.blocking, &(review.outcomes[&1.fingerprint] == :dismissed)) do
      [] -> {:noreply, %{state | notice: "No blocking findings to fix"}}
      findings -> fix(state, findings)
    end
  end

  def handle(:rereview, %State{review: review} = state) do
    cond do
      running?(review) ->
        {:noreply, %{state | notice: "The review is still running"}}

      busy?(state) ->
        {:noreply, %{state | notice: "Re-review when the agent is idle"}}

      review.status in [:failed, :cancelled] ->
        {:noreply, %{state | notice: "The review did not finish · /review starts a new one"}}

      not rereviewable?(review) ->
        {:noreply, %{state | notice: "Nothing to re-review · /review starts a review"}}

      true ->
        launch(state, %{review | mode: :rereview}, review.change)
    end
  end

  def handle(:cancel, %State{review: review} = state) do
    if running?(review) and review.status != :cancelling do
      Cancellation.cancel(review.signal)

      {:noreply,
       %{state | review: %{review | status: :cancelling}, notice: "Cancelling the review…"}}
    else
      {:noreply, state, render?: false}
    end
  end

  defp fix(state, findings) do
    cond do
      busy?(state) ->
        {:noreply, %{state | notice: "Fixes can be sent when the agent is idle"}}

      Input.get_value(state.input) != "" ->
        {:noreply, %{state | notice: "Clear the draft before sending a fix"}}

      true ->
        {review, saved} = record(state.review, findings, :fixed)
        state = %{state | review: review, overlay: nil}

        case Composer.submit_prompt(state, fix_prompt(findings)) do
          {:noreply, state} ->
            {:noreply, %{state | notice: fix_notice(findings) <> saved}}

          {:noreply, state, opts} ->
            {:noreply, %{state | notice: fix_notice(findings) <> saved}, opts}
        end
    end
  end

  defp fix_notice([_one]), do: "Fix requested · /findings reopens the review"

  defp fix_notice(many),
    do: "Fix requested for #{length(many)} findings · /findings reopens the review"

  defp busy?(state), do: state.active_turn != nil or state.pending_operation != nil

  # Writes the outcome of every finding to the history and remembers it for
  # the list. Returns the notice suffix when the history did not take it.
  defp record(review, findings, outcome) do
    results =
      for %Finding{fingerprint: fingerprint} <- findings, is_binary(fingerprint) do
        write_outcome(review.history, fingerprint, outcome)
      end

    marks = for %Finding{fingerprint: fp} <- findings, is_binary(fp), into: %{}, do: {fp, outcome}
    review = %{review | outcomes: Map.merge(review.outcomes, marks)}

    saved =
      cond do
        is_nil(review.history) -> " · history unavailable, not saved"
        error = Enum.find(results, &match?({:error, _reason}, &1)) -> not_saved(error)
        true -> ""
      end

    {review, saved}
  end

  defp write_outcome(nil, _fingerprint, _outcome), do: :ok

  defp write_outcome(history, fingerprint, outcome),
    do: History.record_outcome(history, fingerprint, outcome)

  defp not_saved({:error, reason}), do: " · not saved: #{History.format_error(reason)}"

  defp outcome_notice(:useful), do: "Marked useful"
  defp outcome_notice(:not_useful), do: "Marked not useful"
  defp outcome_notice(:dismissed), do: "Dismissed · later reviews skip it"

  defp clamp(review) do
    count = length(findings(review))
    %{review | selected: min(review.selected, max(count - 1, 0)), scroll: 0}
  end

  # -- fix prompt -------------------------------------------------------------

  @doc """
  The prompt that asks the chat agent to fix `findings`.

  Each finding contributes its location, severity, category, rule, title,
  trigger, explanation, and suggestion, so the agent can act without the
  overlay.
  """
  @spec fix_prompt([Finding.t(), ...]) :: String.t()
  def fix_prompt([finding]) do
    Enum.join(
      [
        "Fix this code review finding:",
        describe(finding),
        "Read the code first, keep the change focused on this finding, and say if you " <>
          "think the finding is wrong instead of changing the code."
      ],
      "\n\n"
    )
  end

  def fix_prompt(findings) when is_list(findings) do
    numbered =
      findings
      |> Enum.with_index(1)
      |> Enum.map(fn {finding, number} -> "#{number}. " <> describe(finding) end)

    Enum.join(
      ["Fix these #{length(findings)} code review findings:"] ++
        numbered ++
        [
          "Read the code first, keep each change focused on its finding, and say which " <>
            "findings you think are wrong instead of changing the code for them."
        ],
      "\n\n"
    )
  end

  defp describe(%Finding{} = finding) do
    rule = if finding.rule_id, do: ", rule #{finding.rule_id}", else: ""

    [
      "#{ReviewOutput.location(finding.location)} [#{finding.severity}, " <>
        "#{finding.category}#{rule}] #{finding.title}",
      "Trigger: #{finding.trigger}",
      finding.body,
      if(finding.suggestion, do: "Suggested fix:\n#{finding.suggestion}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end
end

defmodule Tackle.Review.Tools.ReportFindings do
  @moduledoc """
  Structured output tool of the `review-detector` profile: reports the
  findings of one review unit.

  A run may report its findings in several calls: each call records the
  findings it carries, and `done: false` says that the run is still
  reviewing. Reporting findings as soon as they are confirmed means that a
  run which later fails (on a timeout, the step limit, or a provider error)
  still contributes what it found. The run's last call leaves `done` out or
  sets it to `true`; `finished?/2` tells whether a run got that far.

  Each finding is validated with `Tackle.Review.Finding.from_input/2` (cited
  rules must apply to the unit) and its location with
  `Tackle.Review.Locations.check/2` (it must overlap a changed line of the
  unit). Invalid findings are not recorded; their errors are returned to the
  model so it can correct and report them again.

  The tool keeps no state. The review orchestrator reads the reported
  findings back from the finished run's transcript with `collect/2`, which
  applies the same validation, so the run's result is exactly what the model
  was told was recorded.

  The unit comes from the trusted session context under `:review` (see
  `t:review_context/0`), which `Tackle.Review.Detector` sets for each run.
  Outside a detector run the tool refuses to work.
  """

  use Tackle.Lib.Tool

  alias Tackle.Lib.Tool
  alias Tackle.Review.{Finding, Locations}

  @max_findings 20

  tool_name("report_findings")

  description("""
  Report findings of the review unit. Each call records the findings it carries; never \
  repeat recorded ones. While you are still reviewing, report the findings you have \
  confirmed with done set to false, so they are kept even if your run is interrupted. \
  Finish with a call that leaves done out or sets it to true, carrying the remaining \
  findings or an empty list. Resend only findings the tool rejected, corrected. \
  Each finding is an object with: title (imperative, at most 80 characters), category \
  (correctness, security, performance, maintainability, readability, testing), severity \
  (blocker, high, medium, low), blocking (true for a functional problem that must be fixed \
  before merging), confidence (0 to 1), rule_id (id of the cited rule, or null), location \
  ({path, side: "new" or "old", start_line, end_line} overlapping changed lines), trigger \
  (the concrete input or condition under which the code fails), body (one short \
  paragraph), and suggestion (replacement code that fully fixes it, or null).\
  """)

  input do
    field(:findings, {:list, :map},
      required: true,
      description:
        "Findings of this unit not reported yet, at most #{@max_findings} per call; an " <>
          "empty list for none"
    )

    field(:done, :boolean,
      description:
        "false when you are still reviewing and will report more; true (the default) for " <>
          "your last report"
    )
  end

  @typedoc """
  The detector run's trusted context, under `:review` in the session context:
  the unit id, the lines its findings may point at, and the ids of the rules
  that apply to it.
  """
  @type review_context :: %{
          required(:stage) => :detector,
          required(:unit_id) => String.t(),
          required(:allowed) => Locations.t(),
          required(:rule_ids) => [String.t()]
        }

  @spec run(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(%{"findings" => findings} = args, context) when is_list(findings) do
    with {:ok, review} <- review_context(context) do
      findings |> accept(review) |> respond(Map.get(args, "done") != false)
    end
  end

  def run(_args, _context), do: {:error, "report_findings requires a findings list"}

  @impl true
  def model_error(reason) when is_binary(reason), do: reason
  def model_error(_reason), do: nil

  @doc """
  Validates reported findings against a unit.

  Returns the valid findings, in order, and one `"findings[i].field: message"`
  error per problem (`i` counts from 1).
  """
  @spec accept([term()], review_context()) :: {[Finding.t()], [String.t()]}
  def accept(findings, _review) when length(findings) > @max_findings do
    {[],
     [
       "findings: #{length(findings)} findings is too many; report at most #{@max_findings}, " <>
         "the most important first"
     ]}
  end

  def accept(findings, %{allowed: allowed, rule_ids: rule_ids}) when is_list(findings) do
    {accepted, errors} =
      findings
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {input, index}, {accepted, errors} ->
        case validate(input, allowed, rule_ids) do
          {:ok, finding} ->
            {[finding | accepted], errors}

          {:error, messages} ->
            {accepted, Enum.reverse(Enum.map(messages, &"findings[#{index}].#{&1}"), errors)}
        end
      end)

    {Enum.reverse(accepted), Enum.reverse(errors)}
  end

  @doc """
  Collects the findings recorded during a run from its transcript.

  Only `report_findings` calls that received a tool result count; their
  arguments are validated again with `accept/2`, in transcript order. A
  finding reported again unchanged counts once.
  """
  @spec collect([Tackle.Lib.Message.t()], review_context()) :: [Finding.t()]
  def collect(messages, review) when is_list(messages) do
    for({_args, accepted} <- reports(messages, review), finding <- elem(accepted, 0), do: finding)
    |> Enum.uniq()
  end

  @doc """
  Returns whether the run recorded its last report: an answered
  `report_findings` call without `done: false` that the tool accepted, even
  one reporting no findings.

  A run that ends with an error after such a call has still reviewed its
  unit; one without it has not, though the findings it reported before
  (`collect/2`) still count.
  """
  @spec finished?([Tackle.Lib.Message.t()], review_context()) :: boolean()
  def finished?(messages, review) when is_list(messages) do
    Enum.any?(reports(messages, review), fn {args, accepted} ->
      Map.get(args, "done") != false and recorded?(accepted)
    end)
  end

  @doc """
  Returns whether the run has nothing left to report: its latest answered
  `report_findings` call is its last one (without `done: false`) and the
  tool accepted every finding it carried.

  A last call with invalid findings is not complete, as the run was asked to
  correct and report them again. `Tackle.Review.Detector` stops a run once
  this holds (`Tackle.Review.Delegation`, `:done?`).
  """
  @spec complete?([Tackle.Lib.Message.t()], review_context()) :: boolean()
  def complete?(messages, review) when is_list(messages) do
    case List.last(reports(messages, review)) do
      {args, {_accepted, []}} -> Map.get(args, "done") != false
      _other -> false
    end
  end

  # The validated arguments of every answered `report_findings` call, with
  # what `accept/2` makes of their findings.
  defp reports(messages, review) do
    answered = answered_call_ids(messages)

    for %{role: :assistant, tool_calls: calls} when is_list(calls) <- messages,
        call <- calls,
        call_field(call, :name) == "report_findings",
        MapSet.member?(answered, call_field(call, :id)),
        {:ok, %{"findings" => findings} = args} <- [validate_args(call_field(call, :arguments))],
        do: {args, accept(findings, review)}
  end

  @doc false
  @spec answered_call_ids([Tackle.Lib.Message.t()]) :: MapSet.t(String.t())
  def answered_call_ids(messages) do
    for %{role: :tool, tool_call_id: id} when is_binary(id) <- messages,
        into: MapSet.new(),
        do: id
  end

  @doc false
  @spec call_field(map(), atom()) :: term()
  def call_field(call, key), do: Map.get(call, key) || Map.get(call, Atom.to_string(key))

  defp validate_args(arguments) when is_map(arguments),
    do: Tool.validate_args(__MODULE__, arguments)

  defp validate_args(_arguments), do: {:error, :invalid_arguments}

  defp validate(input, allowed, rule_ids) do
    with {:ok, finding} <- Finding.from_input(input, rule_ids: rule_ids),
         :ok <- check_location(finding.location, allowed) do
      {:ok, finding}
    end
  end

  defp check_location(location, allowed) do
    case Locations.check(location, allowed) do
      :ok -> :ok
      {:error, message} -> {:error, [message]}
    end
  end

  defp review_context(context) do
    case Map.get(context, :review) do
      %{stage: :detector, allowed: %{}, rule_ids: rule_ids} = review when is_list(rule_ids) ->
        {:ok, review}

      _other ->
        {:error, "report_findings is only available in review detector runs"}
    end
  end

  # Mirrors `respond/2`: the call succeeded unless every finding was invalid.
  defp recorded?({[], [_error | _rest]}), do: false
  defp recorded?({_accepted, _errors}), do: true

  defp respond({[], []}, done?), do: {:ok, "Recorded no findings." <> next(done?)}

  defp respond({[], errors}, _done?) do
    {:error,
     "No findings were recorded. Fix these problems and call report_findings again with " <>
       "the corrected findings:\n" <> bullets(errors)}
  end

  defp respond({accepted, []}, done?), do: {:ok, "Recorded #{count(accepted)}." <> next(done?)}

  defp respond({accepted, errors}, done?) do
    {:ok,
     "Recorded #{count(accepted)}." <>
       next(done?) <>
       " The other findings were not recorded; fix these problems and call report_findings " <>
       "again with only those findings:\n" <> bullets(errors)}
  end

  defp next(true), do: ""

  defp next(false),
    do: " Keep reviewing; report further findings, and finish with a call without done: false."

  defp count([_one]), do: "1 finding"
  defp count(findings), do: "#{length(findings)} findings"

  defp bullets(errors), do: Enum.map_join(errors, "\n", &("- " <> &1))
end

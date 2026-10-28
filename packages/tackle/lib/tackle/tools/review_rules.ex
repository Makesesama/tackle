defmodule Tackle.Tools.ReviewRules do
  @moduledoc """
  Opt-in tool that checks the review rules `review_changes` would apply in
  the agent's working directory, so an agent that writes rule files can see
  whether they load.

  It runs `Tackle.LocalReview.Rules.check/1` with the session's executor
  (project rules are read through it, as a review reads them), homes
  (`Tackle.Config.homes/1`), and the built-in rule selection of its review
  settings (`default_rules`), and returns `Tackle.LocalReview.Rules.format_check/1`'s
  text: the files that do not load and why, the rules in effect, and the
  rule directories. Files that do not load are part of the result, not an
  error. The CLI's `tackle review rules` prints the same text.

  `skill_markdown/0` is a guide to writing rules for hosts to offer as a
  built-in skill (`Tackle.Skills.builtin/2`) with
  `requires_tools: ["check_review_rules"]`.
  """

  use Tackle.Lib.Tool

  alias Tackle.Config
  alias Tackle.Executor
  alias Tackle.LocalReview.Rules, as: RuleDiscovery
  alias Tackle.Review.Settings, as: ReviewSettings

  # Embedded at compile time, so escripts and releases without `priv` have it.
  @skill_path Path.join(__DIR__, "review_rules/SKILL.md")
  @external_resource @skill_path
  @skill_markdown File.read!(@skill_path)

  tool_name("check_review_rules")

  description(
    "Check the code review rules that apply in the working directory: lists the rules in " <>
      "effect (built-in, user, and project), the rule files that do not load and why, and " <>
      "where project rules go. Run it after writing or editing a rule file."
  )

  input do
  end

  @impl true
  def effect, do: :read_only

  @doc """
  A guide to writing review rules, as a skill's `SKILL.md` with front
  matter. It is embedded at compile time.
  """
  @spec skill_markdown() :: String.t()
  def skill_markdown, do: @skill_markdown

  @spec run(map(), map()) :: {:ok, String.t()}
  def run(_args, context) when is_map(context) do
    opts =
      [
        executor: Executor.from_context(context),
        builtin_rules: builtin_rules(context)
      ] ++ cwd(context) ++ Config.homes(context)

    {:ok, opts |> RuleDiscovery.check() |> RuleDiscovery.format_check()}
  end

  defp cwd(%{cwd: cwd}) when is_binary(cwd), do: [cwd: cwd]
  defp cwd(_context), do: []

  defp builtin_rules(%{review_settings: %ReviewSettings{default_rules: ids}}) when is_list(ids),
    do: ids

  defp builtin_rules(_context), do: :all
end

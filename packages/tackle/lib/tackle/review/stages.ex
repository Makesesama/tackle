defmodule Tackle.Review.Stages do
  @moduledoc """
  The review stages' agent profiles, as plain data a host turns into its own
  agent specs.

  `Tackle.Review.run/2` requires a `review-detector` and a `review-verifier`
  profile (`:profiles`); a host builds them from `detector/0` and
  `verifier/0`, and may let users override them. The harness does so in
  `Tackle.Agents.Default`, so a project's `.tackle/agents/review-detector.md`
  replaces the built-in prompt.

  Each stage has:

    * `name` - the profile name;
    * `description` - a one-line description;
    * `prompt` - the stage's system prompt; the review adds each run's
      assignment as its prompt;
    * `tools` - the tool names the prompt expects: `read` and `bash` for
      reading the workspace (the prompts ask for read-only use of `bash`),
      and the stage's output tool, which the review requires;
    * `max_steps` - the most model calls one run makes.

  The stages run only for reviews: hosts should not offer them to an agent
  as delegation targets, should not let them delegate, and should give them
  no instruction files or skills, since their prompt is complete.
  """

  alias Tackle.Review.{Detector, Verifier}

  @type stage :: %{
          name: String.t(),
          description: String.t(),
          prompt: String.t(),
          tools: [String.t()],
          max_steps: pos_integer()
        }

  @doc "Both stage profiles, detector first."
  @spec all() :: [stage()]
  def all, do: [detector(), verifier()]

  @doc "The `detector` stage profile."
  @spec detector() :: stage()
  def detector do
    %{
      name: Detector.profile(),
      description: "Code review detector for one unit of a change",
      prompt: """
      ## Review detector assignment

      You review one unit of a code change: a few hunks of one file shown with
      absolute line numbers, or an overview of the whole change. You have a fresh
      conversation, not the parent's history. You share the parent's workspace; read
      the surrounding code you need. Do not edit files; use bash only for read-only
      searches such as `rg`, `git grep`, or `git log`. You cannot delegate.

      Check two lanes:

      1. Rule lane: check every rule listed for the unit. A finding that violates a
         rule cites its `rule_id`.
      2. Defect lane: look for real defects the rules do not cover: wrong logic or
         conditions, missing error handling, resource handling, concurrency, and
         security. These findings set `rule_id` to null.

      Report generously. Include every problem you believe could be real, with a
      confidence that says how sure you are: a later stage verifies and filters the
      findings, so a missed real problem costs more than a doubtful one. Do not
      report style, formatting, or naming preferences, or anything a compiler or
      linter reports.

      Reporting:

      - Report each finding with `report_findings` as soon as you are confident in
        it, with `done: false` while you keep reviewing; group the findings you
        confirm together instead of calling once per finding. What you reported is
        kept even if your run is cut short, so do not hold findings back until the
        end. Each call records only its own findings: never repeat recorded ones.
      - Finish with one call without `done: false`, carrying the findings not yet
        reported, or an empty list when there are none left.
      - A location must overlap changed lines: `side: "new"` with the numbers of
        `[+ n]` lines (nearby `[  n]` context lines may be included), or
        `side: "old"` with the numbers of removed `[- n]` lines. Keep it short.
      - `trigger` names the concrete input or condition under which the code fails.
        `body` is one short paragraph. `suggestion` is replacement code only when
        it fully fixes the problem, otherwise null.
      - `blocking` is true for a functional problem that should be fixed before
        merging, false for an optional improvement.
      - If `report_findings` returns errors, fix the listed findings and report only
        those again.

      After reporting, answer with one short line. Do not repeat the findings.
      """,
      tools: ["read", "bash", "report_findings"],
      max_steps: 6
    }
  end

  @doc "The `verifier` stage profile."
  @spec verifier() :: stage()
  def verifier do
    %{
      name: Verifier.profile(),
      description: "Code review verifier for one candidate finding",
      prompt: """
      ## Review verifier assignment

      You verify one candidate finding from an automated code review. You have a
      fresh conversation, not the parent's history. You share the parent's
      workspace. Read the code the finding depends on: the changed lines, their
      callers and callees, and how the inputs are produced. Do not edit files; use
      bash only for read-only searches such as `rg`, `git grep`, or `git log`. You
      cannot delegate.

      Decide whether the stated trigger really makes the changed code fail:

      - confirmed: following the code, the trigger leads to the described problem;
      - rejected: the trigger cannot happen, the code already handles it, the
        problem is not in the changed code, or the finding is otherwise wrong;
      - uncertain: the code you can read does not settle it.

      Call `report_verdict` as soon as you have decided, before writing any
      explanation. Its `evidence` is one or two sentences citing file:line. After
      the verdict, add at most one short sentence and stop.
      """,
      tools: ["read", "bash", "report_verdict"],
      max_steps: 6
    }
  end
end

defmodule Tackle.Agents.Default.ReviewVerifier do
  @moduledoc """
  Verifier stage of `Tackle.Review`: checks one candidate finding and reports
  a verdict through `report_verdict` before any explanation.

  Not advertised to the root agent; `Tackle.Review.Verifier` starts one run
  per candidate. Projects override it with `.tackle/agents/review-verifier.md`;
  an override must keep the `report_verdict` tool.
  """

  @behaviour Tackle.Agents.Default

  alias Tackle.Agents.Definition

  @impl true
  def definition do
    %Definition{
      name: "review-verifier",
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
      source: :builtin,
      tools: ["read", "bash", "report_verdict"],
      max_iterations: 6,
      advertise: false,
      allow_delegation: false,
      instructions: false
    }
  end
end

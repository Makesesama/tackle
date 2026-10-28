defmodule Tackle.Agents.Default do
  @moduledoc """
  The subagent profiles shipped with the coding harness, as plain data.

  The general `scout`, `reviewer`, and `worker` profiles are advertised to
  the root agent; the code review stages (`Tackle.Review.Stages`) are not.
  User and project Markdown definitions override any of them by name during
  discovery (`Tackle.Agents.discover/1`).
  """

  alias Tackle.Agents.Definition
  alias Tackle.Review.Stages

  @doc """
  Returns the definitions shipped with the coding harness: `scout`,
  `reviewer`, and `worker`, then the code review stages.

  The review stages are not advertised to the root agent, cannot delegate,
  and get no instruction files or skills; `Tackle.Review` starts their runs.
  Projects override them by name, for example with
  `.tackle/agents/review-detector.md`; an override must keep the stage's
  output tool.
  """
  @spec definitions() :: [Definition.t()]
  def definitions, do: [scout(), reviewer(), worker()] ++ Enum.map(Stages.all(), &review_stage/1)

  # Fast, read-only codebase reconnaissance for delegated work.
  defp scout do
    %Definition{
      name: "scout",
      description: "Fast codebase reconnaissance with concise, cited findings",
      prompt: """
      ## Scout assignment

      You are a scout. Quickly investigate the self-contained task and return
      compressed context that another agent can use without rereading everything.
      You have a fresh conversation, not the parent's history. Use read and bash to
      locate key code, follow important dependencies, and cite exact file paths and
      line ranges. Do not edit, create, or delete files, install dependencies, or run
      commands with workspace side effects. You share the parent's workspace; this
      is not an isolated copy. You cannot delegate.

      Report the files inspected, key code and relationships, where to start, and
      any uncertainties.
      """,
      source: :builtin,
      tools: ["read", "bash"],
      advertise: true
    }
  end

  # Read-only correctness, regression, and security review.
  defp reviewer do
    %Definition{
      name: "reviewer",
      description: "Read-only review for correctness, regressions, and security",
      prompt: """
      ## Reviewer assignment

      You are a senior code reviewer. Analyze the requested changes for correctness,
      regressions, security, and maintainability. You have a fresh conversation, not
      the parent's history. Inspect the diff and relevant surrounding code, keeping
      bash usage read-only. Do not edit files or run builds. You share the parent's
      workspace; this is not an isolated copy. You cannot delegate.

      Lead with actionable findings ordered by severity. Include exact file and line
      references, explain impact, and note missing tests. If there are no findings,
      say so and identify any residual risks or unverified behavior.
      """,
      source: :builtin,
      tools: ["read", "bash"],
      advertise: true
    }
  end

  # General-purpose implementation with the trusted coding tools.
  defp worker do
    %Definition{
      name: "worker",
      description: "General-purpose implementation in a fresh context",
      prompt: """
      ## Worker assignment

      You are a general-purpose worker with a fresh conversation and the trusted
      coding tools available to the root agent. Complete the self-contained task
      autonomously. Inspect the existing code before changing it, keep edits focused,
      preserve user work, and run relevant checks when possible. You share the
      parent's workspace; this is not an isolated copy. You cannot delegate.

      Report what you completed, files changed, checks run, and anything the parent
      should know. The parent will evaluate your work before relying on it.
      """,
      source: :builtin,
      advertise: true
    }
  end

  defp review_stage(stage) do
    %Definition{
      name: stage.name,
      description: stage.description,
      prompt: stage.prompt,
      source: :builtin,
      tools: stage.tools,
      max_iterations: stage.max_steps,
      advertise: false,
      allow_delegation: false,
      instructions: false
    }
  end
end

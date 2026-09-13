defmodule Tackle.Agents.Default.Worker do
  @moduledoc "General-purpose implementation agent with the trusted coding tools."

  @behaviour Tackle.Agents.Default

  alias Tackle.Agents.Definition

  @impl true
  def definition do
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
      advertise: true,
      allow_delegation: false
    }
  end
end

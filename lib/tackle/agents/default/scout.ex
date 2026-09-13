defmodule Tackle.Agents.Default.Scout do
  @moduledoc "Fast, read-only codebase reconnaissance for delegated work."

  @behaviour Tackle.Agents.Default

  alias Tackle.Agents.Definition

  @impl true
  def definition do
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
      advertise: true,
      allow_delegation: false
    }
  end
end

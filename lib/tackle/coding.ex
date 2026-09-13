defmodule Tackle.Coding do
  @moduledoc """
  Composition of a coding scope with the built-in explorer profile.

  The CLI uses this policy by default; `Tackle.Config`, `Tackle.Tools.default/0`,
  and the general runtime remain unchanged. Explorer runs are ephemeral, use a
  fresh conversation, and cannot delegate. They share the configured workspace
  and use the requesting root's current model/thinking selection at request
  time, not its conversation history. Existing child runs are never reconfigured.

  The explorer has `read` and `bash` (only when also available to the root).
  Its no-edit instruction is policy, not a sandbox: bash retains OS permissions.
  """

  alias Tackle.Config
  alias Tackle.Runtime.{AgentSpec, ScopeSpec}
  alias Tackle.Session.Spec, as: SessionSpec
  alias Tackle.Tools.{Bash, Read, Subagent}

  @delegation """
  ## Delegation

  Use the subagent tool with profile "explorer" for bounded code investigation.
  Supply a self-contained prompt with the relevant context and expected deliverable;
  the explorer does not see this conversation. Prefer doing trivial tasks yourself.
  The explorer shares this workspace, uses read and bash, and is instructed not to
  edit files (this is not a sandbox). It cannot delegate or be messaged again.
  Evaluate its returned findings before relying on them. Ask for file and line
  references and a concise summary of uncertainties. At most two explorers can
  run at once; excess requests are rejected, not queued.
  """

  @exploration """
  ## Explorer assignment

  You are the explorer subagent. Investigate only the self-contained task in the
  user prompt and return concise findings with file paths, line references, and
  uncertainties. You have a fresh conversation, not the parent's history.
  Use read to inspect files and bash to list and search the codebase. Do not edit,
  create, or delete files, install dependencies, or run commands with workspace
  side effects. You share the parent's workspace; this is not an isolated copy.
  You cannot delegate. Return your findings rather than implementing changes.
  """

  @doc """
  Loads coding configuration and builds a scope with an explorer allowlist.

  Accepts `Tackle.Config.load/1` options and an optional durable root session.
  Both prompts load the same instruction files with their respective tool sets.
  Each explorer is bounded to 20 loop iterations and five minutes. Scope limits
  allow the root plus two children, with no recursive delegation.
  """
  @spec scope_spec(keyword(), SessionSpec.t() | nil) :: {:ok, ScopeSpec.t()} | {:error, term()}
  def scope_spec(loader_opts \\ [], session \\ nil) do
    with {:ok, config} <- Config.load(loader_opts),
         {:ok, root_config} <- load_tools(loader_opts, Enum.uniq(config.tools ++ [Subagent])),
         {:ok, explorer_config} <-
           load_tools(loader_opts, Enum.filter(config.tools, &(&1 in [Read, Bash]))),
         {:ok, root_spec} <-
           AgentSpec.new(
             name: "root",
             config: append_prompt(root_config, @delegation),
             allow_delegation: true
           ),
         {:ok, explorer_spec} <- explorer_spec(explorer_config) do
      ScopeSpec.new(
        root_spec: root_spec,
        session: session,
        limits: limits(),
        profiles: %{"explorer" => explorer_spec}
      )
    end
  end

  defp load_tools(opts, tools) do
    overrides = opts |> Keyword.get(:overrides, []) |> Keyword.put(:tools, tools)
    Config.load(Keyword.put(opts, :overrides, overrides))
  end

  defp explorer_spec(config) do
    config = %{
      append_prompt(config, @exploration)
      | max_iterations: min_iterations(config.max_iterations),
        llm_stream: false
    }

    AgentSpec.new(
      name: "explorer",
      config: config,
      allow_delegation: false,
      model_source: :parent
    )
  end

  defp append_prompt(config, section),
    do: %{config | system_prompt: Enum.join([config.system_prompt, section], "\n\n")}

  defp min_iterations(:infinity), do: 20
  defp min_iterations(value), do: min(value, 20)

  defp limits do
    [
      max_agents_per_fleet: 3,
      max_concurrent_turns: 3,
      max_children_per_agent: 2,
      max_spawn_depth: 1,
      run_timeout: :timer.minutes(5)
    ]
  end
end

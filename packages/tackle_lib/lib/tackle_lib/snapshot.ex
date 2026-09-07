defmodule Tackle.Lib.Snapshot do
  @moduledoc """
  Immutable per-turn snapshot of the agent's configuration.

  Captured at the start of every turn, this struct freezes the tool registry,
  hook modules, LLM configuration, system prompt, and version identifiers so
  that the turn's execution operates against a stable baseline. No field on the
  snapshot is mutable after creation.

  ## Why snapshots?

  Without a snapshot, a long-running agent could observe tool or hook changes
  mid-turn (e.g. a hot-code reload, a dynamically registered tool). The snapshot
  guarantees that every step of a single turn sees the same configuration,
  making behaviour deterministic and auditable.

  ## Version IDs

  `system_prompt_version_id` and `tools_version_id` are deterministic hashes
  computed at capture time. They provide stable identifiers for auditing and
  caching without leaking the full snapshot content.
  """

  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.Tool
  alias Tackle.Lib.Tool.Registry

  @type t :: %__MODULE__{
          turn_id: String.t(),
          system_prompt: String.t() | nil,
          system_prompt_version_id: String.t() | nil,
          prompt_renderer: module() | nil,
          prompt_renderer_opts: keyword(),
          tools_version_id: String.t(),
          tools: [module()],
          tool_registry: Registry.t(),
          hooks: [module()],
          llm: Selection.t() | nil,
          llm_adapter: module() | nil,
          model: String.t() | nil,
          model_ref: String.t() | nil,
          llm_opts: keyword(),
          captured_at: DateTime.t()
        }

  defstruct [
    :turn_id,
    :system_prompt,
    :system_prompt_version_id,
    :prompt_renderer,
    :prompt_renderer_opts,
    :tools_version_id,
    :tools,
    :tool_registry,
    :hooks,
    :llm,
    :llm_adapter,
    :model,
    :model_ref,
    :llm_opts,
    :captured_at
  ]

  @doc """
  Captures a snapshot from the current agent state and runtime configuration.

  Uses the state's explicit LLM selection when present, otherwise resolving the
  configured default adapter for compatibility. The selected adapter is frozen
  so the turn is isolated from adapter swaps. Computes version IDs for the
  system prompt and tool set.
  """
  @spec capture(map(), keyword()) :: t()
  def capture(state, opts \\ []) when is_map(state) do
    turn_id = Keyword.get(opts, :turn_id) || generate_turn_id(state)
    hooks = Keyword.get(opts, :hooks) || Map.get(state, :hooks, []) || []
    llm = Map.get(state, :llm)
    {llm_adapter, model, model_ref} = resolve_llm(llm, state)
    system_prompt = Map.get(state, :system_prompt)
    prompt_renderer = Map.get(state, :prompt_renderer)
    prompt_renderer_opts = Map.get(state, :prompt_renderer_opts, [])
    tools = Map.get(state, :tools, [])

    %__MODULE__{
      turn_id: turn_id,
      system_prompt: system_prompt,
      system_prompt_version_id: system_prompt_version_id(system_prompt),
      prompt_renderer: prompt_renderer,
      prompt_renderer_opts: prompt_renderer_opts,
      tools_version_id: tools_version_id(tools),
      tools: tools,
      tool_registry: Map.get(state, :tool_registry),
      hooks: hooks,
      llm: llm,
      llm_adapter: llm_adapter,
      model: model,
      model_ref: model_ref,
      llm_opts: Map.get(state, :llm_opts, []),
      captured_at: DateTime.utc_now()
    }
  end

  @doc """
  Computes a stable version ID for a system prompt string.

  Uses the same SHA-256 prefix hashing as `Tackle.Lib.Tool.definition_id/1` so
  all definition/version identifiers share one canonical style.

  Returns `nil` when the prompt is nil.
  """
  @spec system_prompt_version_id(String.t() | nil) :: String.t() | nil
  def system_prompt_version_id(nil), do: nil

  def system_prompt_version_id(prompt) when is_binary(prompt) do
    Tackle.Lib.SystemPrompt.version_id(prompt)
  end

  @doc """
  Computes a stable version ID for a list of tool modules.

  Hashes the aggregated provider-neutral definitions so the id changes when any
  tool's name, description, or schema changes.
  """
  @spec tools_version_id([module()]) :: String.t()
  def tools_version_id(tools) when is_list(tools) do
    tools
    |> Enum.map(&Tool.definition/1)
    |> Enum.map(&Map.drop(&1, [:definition_id]))
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc """
  Returns the frozen tool registry from the snapshot.

  This is the authoritative tool registry for the turn — use it instead of
  `state.tool_registry` to avoid mid-turn drift.
  """
  @spec tool_registry(t()) :: Registry.t()
  def tool_registry(%__MODULE__{tool_registry: registry}), do: registry

  @doc """
  Returns the frozen hook module list from the snapshot.
  """
  @spec hooks(t()) :: [module()]
  def hooks(%__MODULE__{hooks: hooks}), do: hooks

  defp resolve_llm(%Selection{} = selection, _state) do
    {selection.adapter, selection.model, selection.ref}
  end

  defp resolve_llm(nil, state) do
    model = Map.get(state, :model)
    {resolve_default_adapter(), model, model}
  end

  defp resolve_default_adapter do
    Tackle.Lib.LLM.adapter()
  rescue
    _ -> nil
  end

  defp generate_turn_id(state) when is_map(state) do
    session_id = Map.get(state, :session_id) || "unknown"
    "#{session_id}-#{System.unique_integer([:positive])}"
  end
end

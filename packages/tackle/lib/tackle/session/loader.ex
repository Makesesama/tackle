defmodule Tackle.Session.Loader do
  @moduledoc """
  Rebuilds a fresh `%Tackle.Lib.State{}` from a durable projection.

  Loading combines durable conversation data with current trusted executable
  configuration. It never restores PIDs, Tasks, runtime references, credential
  handles, executable modules, or stale process state; a resumed conversation
  always starts a new runtime scope.

  When the recorded configuration cannot be resolved against the current
  providers, loading returns a typed `:configuration_required` error instead of
  silently switching providers or models.

  ## Branching and non-branching sessions

  A projection always folds a `Tackle.Lib.Tree`, and the runtime state always
  keeps one, so one restoration path serves every session: the projection's
  tree is installed as is. A journal written before branching existed is a
  chain, so it loads as a tree with one branch. Whether the session may
  branch (`tree_enabled?`) is host policy that `Tackle.Session` enforces; it
  does not change what is loaded.
  """

  alias Tackle.Config
  alias Tackle.Lib.State, as: AgentState
  alias Tackle.Lib.Thinking
  alias Tackle.Session.Projection

  @type result :: %{
          state: AgentState.t(),
          config: Config.t(),
          configuration_changed?: boolean()
        }

  @doc """
  Builds a fresh runtime state from a projection and configuration.

  The recorded selection is the pair of model and thinking level the journal
  last recorded. A recorded `nil` thinking level means no explicit level was
  set, so the restored configuration carries none.

  `:override_config` (false by default) tells the loader the caller explicitly
  selected the supplied configuration, so the recorded selection is superseded
  and `configuration_changed?` reports whether the supplied model or thinking
  level differs from it and must be persisted. Otherwise the recorded
  selection is restored through the current providers.

  Returns the state together with the resolved configuration, which the
  session keeps for later reconfiguration and title generation.
  """
  @spec load(Projection.t(), Config.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def load(%Projection{} = projection, %Config{} = config, opts \\ []) do
    with {:ok, resolved, changed?} <- resolve_config(projection, config, opts) do
      state =
        resolved
        |> Config.to_agent_state(session_id: projection.session_id)
        # The projection folds its tree through `Tree.append_message/3` and
        # `Tree.append_compaction/3`, which validate every link and keep the
        # child index, and rejects a journal they refuse, so its tree is
        # installed as is.
        |> AgentState.put_tree(projection.tree)
        |> AgentState.reset_turn()

      {:ok, %{state: state, config: resolved, configuration_changed?: changed?}}
    end
  end

  defp resolve_config(%Projection{model_ref: recorded} = projection, config, opts) do
    current = {config.model_ref, Thinking.from_llm_opts(config.llm_opts)}
    recorded_thinking = recorded_thinking(projection.thinking)

    cond do
      Keyword.get(opts, :override_config, false) ->
        {:ok, config, current != {recorded, recorded_thinking}}

      is_nil(recorded) or current == {recorded, recorded_thinking} ->
        {:ok, config, false}

      true ->
        restore_selection(config, recorded, recorded_thinking, projection)
    end
  end

  # Journals record the normalized level; earlier versions recorded the
  # adapter option as is, `nil` when no level was set.
  defp recorded_thinking(thinking) do
    case Thinking.parse(thinking) do
      {:ok, nil} -> "off"
      {:ok, level} -> level
      {:error, _reason} -> {:invalid, thinking}
    end
  end

  defp restore_selection(config, recorded, thinking, projection) do
    with level when is_binary(level) <- thinking,
         {:ok, resolved} <- Config.update(config, model: recorded, thinking: level) do
      {:ok, resolved, false}
    else
      _invalid ->
        {:error,
         {:configuration_required,
          %{model: recorded, thinking: projection.thinking, available: config.model_ref}}}
    end
  end
end

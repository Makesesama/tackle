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
  alias Tackle.Session.Codec
  alias Tackle.Session.Projection

  @type result :: %{state: AgentState.t(), configuration_changed?: boolean()}

  @doc """
  Builds a fresh runtime state from a projection and configuration.

  `:override_config` (false by default) tells the loader the caller explicitly
  selected the supplied configuration, so the recorded selection is superseded
  and a configuration change must be persisted. Otherwise the recorded
  selection is re-resolved through the current providers.
  """
  @spec load(Projection.t(), Config.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def load(%Projection{} = projection, %Config{} = config, opts \\ []) do
    with {:ok, resolved, changed?} <- resolve_config(projection, config, opts) do
      state =
        resolved
        |> Config.to_agent_state(
          credential_store: Keyword.get(opts, :credential_store),
          session_id: projection.session_id
        )
        # The projection folds its tree through `Tree.append_message/3` and
        # `Tree.append_compaction/3`, which validate every link and keep the
        # child index, and rejects a journal they refuse, so its tree is
        # installed as is.
        |> AgentState.put_tree(projection.tree)
        |> AgentState.reset_turn()

      {:ok, %{state: state, configuration_changed?: changed?}}
    end
  end

  @doc """
  Resolves the effective configuration for a recorded session.

  Returns `{:ok, config, changed?}` where `changed?` reports that the supplied
  configuration differs from the recorded selection and must be persisted.
  """
  @spec resolve_config(Projection.t(), Config.t(), keyword()) ::
          {:ok, Config.t(), boolean()} | {:error, term()}
  def resolve_config(%Projection{} = projection, %Config{} = config, opts) do
    recorded = projection.model_ref

    cond do
      Keyword.get(opts, :override_config, false) ->
        {:ok, config, config.model_ref != recorded}

      is_nil(recorded) or recorded == config.model_ref ->
        {:ok, config, false}

      true ->
        case Config.reconfigure(config, model: recorded, thinking: projection.thinking) do
          {:ok, resolved} ->
            {:ok, resolved, false}

          {:error, _reason} ->
            {:error,
             {:configuration_required,
              %{model: recorded, thinking: projection.thinking, available: config.model_ref}}}
        end
    end
  end

  @doc "Decodes durable messages in order, failing on the first invalid message."
  @spec decode_messages([map()]) :: {:ok, [Tackle.Lib.Message.t()]} | {:error, term()}
  def decode_messages(messages) when is_list(messages) do
    messages
    |> Enum.reduce_while({:ok, []}, fn data, {:ok, acc} ->
      case Codec.decode_message(data) do
        {:ok, message} -> {:cont, {:ok, [message | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _reason} = error -> error
    end
  end
end

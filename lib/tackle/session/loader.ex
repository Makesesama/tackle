defmodule Tackle.Session.Loader do
  @moduledoc """
  Rebuilds a fresh `%Tackle.Lib.State{}` from a durable projection.

  Loading combines durable conversation data with current trusted executable
  configuration. It never restores PIDs, Tasks, runtime references, credential
  handles, executable modules, or stale process state; a resumed conversation
  always starts a new runtime scope.

  When the recorded configuration cannot be resolved against the current
  adapters, loading returns a typed `:configuration_required` error instead of
  silently switching providers or models.

  ## Linear and branching sessions

  A projection always folds a `Tackle.Lib.Tree`, so one restoration path serves
  both shapes. A session whose projection is marked `tree_enabled?` is restored
  with an active tree; requesting `tree: true` also adopts the derived chain of a
  legacy linear journal (the host records the explicit `tree.enabled` transition
  separately). A tree-enabled session is never silently flattened: the tree is
  restored or a typed error is returned.
  """

  alias Tackle.Config
  alias Tackle.Lib.State, as: AgentState
  alias Tackle.Lib.Tree
  alias Tackle.Session.Codec
  alias Tackle.Session.Projection

  @type result :: %{state: AgentState.t(), configuration_changed?: boolean()}

  @doc """
  Builds a fresh runtime state from a projection and configuration.

  `:override_config` (false by default) tells the loader the caller explicitly
  selected the supplied configuration, so the recorded selection is superseded
  and a configuration change must be persisted. Otherwise the recorded
  selection is re-resolved through the current adapters.

  `:tree` (false by default) requests branching support for a session whose
  journal predates tree enablement; the derived chain becomes the active tree.
  """
  @spec load(Projection.t(), Config.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def load(%Projection{} = projection, %Config{} = config, opts \\ []) do
    with {:ok, resolved, changed?} <- resolve_config(projection, config, opts),
         {:ok, conversation} <- decode_conversation(projection, opts) do
      state =
        resolved
        |> Config.to_agent_state(credential_store: Keyword.get(opts, :credential_store))
        |> install(projection.session_id, conversation)

      {:ok, %{state: state, configuration_changed?: changed?}}
    end
  end

  defp decode_conversation(%Projection{tree_enabled?: true} = projection, _opts) do
    restore_tree(projection)
  end

  defp decode_conversation(%Projection{} = projection, opts) do
    if Keyword.get(opts, :tree, false) do
      restore_tree(projection)
    else
      decode_linear(projection)
    end
  end

  defp restore_tree(%Projection{tree: nil}), do: restore_tree_value(Tree.new())

  defp restore_tree(%Projection{tree: %Tree{} = tree}), do: restore_tree_value(tree)

  defp restore_tree_value(%Tree{} = tree) do
    descriptors = tree |> Tree.enumerate() |> Enum.map(&Map.from_struct/1)

    case Tree.restore(descriptors, active_id: tree.active_id) do
      {:ok, tree} ->
        {:ok,
         %{
           tree: tree,
           messages: Tree.transcript(tree),
           model_messages: Tree.model_context(tree)
         }}

      {:error, reason} ->
        {:error, {:invalid_tree, reason}}
    end
  end

  defp decode_linear(%Projection{} = projection) do
    with {:ok, messages} <- decode_messages(projection.messages),
         {:ok, model_messages} <- decode_model_messages(projection, messages) do
      {:ok, %{tree: nil, messages: messages, model_messages: model_messages}}
    end
  end

  # Older journals precede the model-surface projection. An empty projection is
  # the mirror-the-transcript default, so replaying them yields the full history
  # as the provider-visible array.
  defp decode_model_messages(%Projection{model_messages: []}, messages), do: {:ok, messages}

  defp decode_model_messages(%Projection{model_messages: model_messages}, _messages),
    do: decode_messages(model_messages)

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

  defp install(%AgentState{} = state, session_id, conversation) do
    tree = Map.get(conversation, :tree)

    %{
      state
      | session_id: session_id,
        messages: conversation.messages,
        model_messages: conversation.model_messages,
        tree: tree,
        last_compaction_id: tree && Tree.last_compaction_id(tree),
        current_iteration: 0,
        status: :idle,
        error: nil,
        snapshot: nil,
        pending_assistant_id: nil,
        overflow_retries: 0
    }
  end
end

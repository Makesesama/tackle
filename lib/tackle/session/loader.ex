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
  selection is re-resolved through the current adapters.
  """
  @spec load(Projection.t(), Config.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def load(%Projection{} = projection, %Config{} = config, opts \\ []) do
    with {:ok, resolved, changed?} <- resolve_config(projection, config, opts),
         {:ok, messages} <- decode_messages(projection.messages) do
      state =
        resolved
        |> Config.to_agent_state(credential_store: Keyword.get(opts, :credential_store))
        |> install(projection.session_id, messages)

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

  defp install(%AgentState{} = state, session_id, messages) do
    %{
      state
      | session_id: session_id,
        messages: messages,
        current_iteration: 0,
        status: :idle,
        error: nil,
        snapshot: nil,
        pending_assistant_id: nil
    }
  end
end

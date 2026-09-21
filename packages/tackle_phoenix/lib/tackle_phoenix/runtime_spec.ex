defmodule Tackle.Phoenix.RuntimeSpec do
  @moduledoc """
  Trusted configuration used by `Tackle.Phoenix.RuntimeBackend` for one agent.

  The host supplies the ordinary Runner configuration and host-managed state.
  Child profiles should use their own `host_state`/`session_id` so persistence,
  quota, and billing remain isolated and every delegated turn still passes
  through the configured `Tackle.Phoenix.Store`.
  """

  alias Tackle.Lib.State

  @enforce_keys [:runner, :user_id, :agent_state, :host_state]
  defstruct [:runner, :user_id, :agent_state, :host_state, :session_id, turn_opts: []]

  @type t :: %__MODULE__{
          runner: map(),
          user_id: String.t(),
          agent_state: State.t(),
          host_state: term(),
          session_id: String.t() | nil,
          turn_opts: keyword()
        }

  @doc "Builds and validates a Phoenix runtime specification."
  @spec new(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = spec), do: validate(spec)
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()

  def new(%{runner: runner, user_id: user_id, agent_state: agent_state} = opts) do
    validate(%__MODULE__{
      runner: runner,
      user_id: user_id,
      agent_state: agent_state,
      host_state: Map.get(opts, :host_state),
      session_id: Map.get(opts, :session_id),
      turn_opts: Map.get(opts, :turn_opts, [])
    })
  end

  def new(value), do: {:error, {:invalid_phoenix_runtime_spec, value}}

  @doc "Builds a validated specification or raises."
  def new!(value) do
    case new(value) do
      {:ok, spec} -> spec
      {:error, reason} -> raise ArgumentError, "invalid Phoenix runtime spec: #{inspect(reason)}"
    end
  end

  defp validate(%__MODULE__{} = spec) do
    required_runner_keys = [
      :registry,
      :dynamic_supervisor,
      :task_supervisor,
      :pubsub,
      :store,
      :agent
    ]

    cond do
      not is_map(spec.runner) ->
        {:error, {:invalid_runner_config, spec.runner}}

      not Enum.all?(required_runner_keys, &Map.has_key?(spec.runner, &1)) ->
        {:error, {:invalid_runner_config, spec.runner}}

      not (is_binary(spec.user_id) and spec.user_id != "") ->
        {:error, {:invalid_user_id, spec.user_id}}

      not is_struct(spec.agent_state, State) ->
        {:error, {:invalid_agent_state, spec.agent_state}}

      not (is_nil(spec.session_id) or is_binary(spec.session_id)) ->
        {:error, {:invalid_session_id, spec.session_id}}

      not is_list(spec.turn_opts) ->
        {:error, {:invalid_turn_options, spec.turn_opts}}

      true ->
        {:ok, spec}
    end
  end
end

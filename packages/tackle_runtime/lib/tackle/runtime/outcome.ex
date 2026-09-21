defmodule Tackle.Runtime.Outcome do
  @moduledoc """
  Terminal outcome of one delegated run.

  A run distinguishes normal library settlement from runtime failures:

  * `:ok` / `:error` / `:cancelled` carry the settled `Tackle.Lib.State`;
  * `:runtime_error` is a turn Task or agent process crash;
  * `:timeout` is an expired request wait;
  * `:rejected` is a fleet/scope policy refusal.

  The struct is internal to the runtime. Model-facing callers project it with
  `to_lib_result/1` or `Tackle.Runtime.Outcome.message/1`.
  """

  alias Tackle.Lib.State

  @statuses [:ok, :error, :cancelled, :runtime_error, :timeout, :rejected]

  @enforce_keys [:status]
  defstruct [:status, :agent_state, :reason, :run_id, :agent_ref]

  @type status :: :ok | :error | :cancelled | :runtime_error | :timeout | :rejected

  @type t :: %__MODULE__{
          status: status(),
          agent_state: State.t() | nil,
          reason: term(),
          run_id: String.t() | nil,
          agent_ref: Tackle.Runtime.AgentRef.t() | nil
        }

  @doc "Builds an outcome and validates the status-specific payload."
  @spec new(status(), keyword()) :: t()
  def new(status, opts \\ []) when status in @statuses do
    outcome = struct!(__MODULE__, Keyword.put(opts, :status, status))
    validate!(outcome)
  end

  @doc "Returns true when the status is a normal library settlement."
  @spec library?(t()) :: boolean()
  def library?(%__MODULE__{status: status}), do: status in [:ok, :error, :cancelled]

  @doc "Returns true when the run settled with a final answer."
  @spec ok?(t()) :: boolean()
  def ok?(%__MODULE__{status: :ok}), do: true
  def ok?(%__MODULE__{}), do: false

  @doc """
  Projects the outcome into a `Tackle.Lib`-style result tuple.

  Runtime failures and rejections become `{:error, reason}` so a parent tool or
  workflow can report them without pretending the library loop failed.
  """
  @spec to_lib_result(t()) ::
          {:ok, State.t()} | {:error, State.t()} | {:cancelled, State.t()} | {:error, term()}
  def to_lib_result(%__MODULE__{status: :ok, agent_state: %State{} = state}), do: {:ok, state}

  def to_lib_result(%__MODULE__{status: :error, agent_state: %State{} = state}),
    do: {:error, state}

  def to_lib_result(%__MODULE__{status: :cancelled, agent_state: %State{} = state}),
    do: {:cancelled, state}

  def to_lib_result(%__MODULE__{status: status, reason: reason}), do: {:error, {status, reason}}

  @doc "Returns the final assistant answer for a successful outcome."
  @spec answer(t()) :: String.t() | nil
  def answer(%__MODULE__{status: :ok, agent_state: %State{} = state}),
    do: Tackle.Lib.last_answer(state)

  def answer(%__MODULE__{}), do: nil

  @doc "Returns a short human-readable description of a non-success outcome."
  @spec message(t()) :: String.t()
  def message(%__MODULE__{status: :ok}), do: "ok"

  def message(%__MODULE__{status: :error, agent_state: %State{error: error}}),
    do: to_string(error)

  def message(%__MODULE__{status: :cancelled}), do: "cancelled"
  def message(%__MODULE__{status: status, reason: reason}), do: "#{status}: #{inspect(reason)}"

  defp validate!(%__MODULE__{status: status} = outcome)
       when status in [:ok, :error, :cancelled] do
    if is_struct(outcome.agent_state, State) do
      outcome
    else
      raise ArgumentError, "library outcome #{status} requires an agent state"
    end
  end

  defp validate!(%__MODULE__{} = outcome), do: outcome
end

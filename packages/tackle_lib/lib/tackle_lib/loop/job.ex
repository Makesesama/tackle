defmodule Tackle.Lib.Loop.Job do
  @moduledoc false

  # One accepted tool call, ready to run. `Tackle.Lib.Loop.Tools` builds it
  # once the call's `before_tool_call` hooks accepted it and settles it inline
  # (sequential policy) or through `Tackle.Lib.Loop.Batch` (concurrent policy).
  # A job carries only what its tool needs, never the agent state:
  #
  #   * `call` - the call being executed;
  #   * `call_signal` - the call's child of the turn's cancellation signal
  #     (`Tackle.Lib.Cancellation.for_call/2`), or `nil` without a turn signal.
  #     Whoever finishes with the job deletes it;
  #   * `execution` - the resolved tool module and its context, or the error
  #     or exception preparing the call produced, which settles the call
  #     without running anything;
  #   * `telemetry_name` - the tool name reported in telemetry.

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Tool.Error

  @type execution ::
          {:ok, module(), map()}
          | {:error, Error.t()}
          | {:raise, :error | :exit | :throw, term(), Exception.stacktrace()}

  @type t :: %__MODULE__{
          call: Call.t(),
          call_signal: Cancellation.signal() | nil,
          execution: execution() | nil,
          telemetry_name: String.t() | nil
        }

  @enforce_keys [:call]
  defstruct [:call, :call_signal, :execution, :telemetry_name]
end

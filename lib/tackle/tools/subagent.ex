defmodule Tackle.Tools.Subagent do
  @moduledoc """
  Opt-in tool that delegates one self-contained task to a fresh subagent.

  The subagent is an ordinary Tackle agent running the same `Tackle.Lib` loop in
  the same root scope. The tool starts one correlated run, waits for its
  terminal outcome, and returns the subagent's final answer as tool output. The
  subagent is ephemeral: it cannot be addressed again after it finishes.

  Delegation is opt-in and permissioned:

    * the host must add this module to a session's tool list;
    * the running agent must carry a runtime handle with delegation granted;
    * the requested profile must be allowlisted in the scope spec.

  Model-visible arguments can only name an allowlisted profile; they can never
  name a module, widen limits, or address a process.
  """

  use Tackle.Lib.Tool

  alias Tackle.Lib.Event
  alias Tackle.Runtime
  alias Tackle.Runtime.Handle
  alias Tackle.Runtime.Outcome

  tool_name("subagent")

  description(
    "Delegate a self-contained task to a fresh subagent and return its final answer. " <>
      "The subagent runs the same agent loop with its own context, so use it to isolate " <>
      "large or parallelizable work. Choose one of the configured profiles. The subagent " <>
      "cannot be messaged again after it finishes."
  )

  input do
    field(:profile, :string,
      required: true,
      description: "Name of the allowlisted subagent profile to run"
    )

    field(:prompt, :string, required: true, description: "Self-contained task for the subagent")

    field(:timeout_ms, :integer,
      description: "Optional maximum wait in milliseconds, bounded by the scope run timeout"
    )
  end

  @spec run(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(%{"profile" => profile, "prompt" => prompt} = args, context)
      when is_binary(profile) and is_binary(prompt) do
    with {:ok, handle} <- fetch_handle(context),
         :ok <- ensure_delegation(handle),
         {:ok, opts} <- timeout_opts(args, handle),
         opts = put_event_callback(opts, context),
         {:ok, run_ref} <- request(handle, profile, prompt, opts) do
      emit(context, :subagent_started, run_ref, profile)
      outcome = Runtime.await(run_ref, :infinity)
      emit(context, :subagent_finished, run_ref, profile, outcome)
      handle_outcome(outcome)
    end
  end

  def run(_args, _context), do: {:error, "subagent requires a profile and a prompt"}

  defp fetch_handle(context) do
    case Handle.from_context(context) do
      %Handle{} = handle -> {:ok, handle}
      nil -> {:error, "subagent is unavailable: this agent has no runtime handle"}
    end
  end

  defp ensure_delegation(%Handle{allow_delegation: true}), do: :ok

  defp ensure_delegation(%Handle{}),
    do: {:error, "subagent delegation is not permitted for this agent"}

  defp timeout_opts(args, %Handle{limits: limits}) do
    case Map.get(args, "timeout_ms") do
      nil ->
        {:ok, []}

      ms when is_integer(ms) and ms > 0 ->
        max = if limits, do: limits.run_timeout, else: ms
        {:ok, [timeout: min(ms, max)]}

      _other ->
        {:error, "timeout_ms must be a positive integer"}
    end
  end

  defp put_event_callback(opts, context) do
    case Map.get(context, :event_callback) do
      callback when is_function(callback, 1) -> Keyword.put(opts, :event_callback, callback)
      _other -> opts
    end
  end

  defp request(handle, profile, prompt, opts) do
    case Runtime.request_agent(handle, profile, prompt, opts) do
      {:ok, run_ref} -> {:ok, run_ref}
      {:error, {:rejected, reason}} -> {:error, "subagent rejected: #{inspect(reason)}"}
      {:error, {:unknown_profile, name}} -> {:error, "unknown subagent profile: #{name}"}
      {:error, reason} -> {:error, "could not start subagent: #{inspect(reason)}"}
    end
  end

  defp emit(context, type, run_ref, profile, outcome \\ nil) do
    case Map.get(context, :event_callback) do
      callback when is_function(callback, 1) ->
        data = %{
          run_id: run_ref.run_id,
          agent_ref: run_ref.agent_ref,
          tool_call_id: Map.get(context, :tool_call_id),
          profile: profile,
          model: run_ref.model_ref,
          status: outcome_status(outcome)
        }

        callback.(Event.new(type, data))

      _other ->
        :ok
    end
  end

  defp outcome_status(nil), do: :running
  defp outcome_status(%Outcome{status: status}), do: status
  defp outcome_status({:error, _reason}), do: :runtime_error

  defp handle_outcome(%Outcome{status: :ok} = outcome),
    do: {:ok, Outcome.answer(outcome) || "(subagent produced no answer)"}

  defp handle_outcome(%Outcome{status: :error} = outcome),
    do: {:error, "subagent failed: #{Outcome.message(outcome)}"}

  defp handle_outcome(%Outcome{status: :cancelled}), do: {:error, "subagent was cancelled"}
  defp handle_outcome(%Outcome{status: :timeout}), do: {:error, "subagent timed out"}

  defp handle_outcome(%Outcome{status: :runtime_error} = outcome),
    do: {:error, "subagent crashed: #{Outcome.message(outcome)}"}

  defp handle_outcome(%Outcome{} = outcome),
    do: {:error, "subagent ended: #{Outcome.message(outcome)}"}

  defp handle_outcome({:error, reason}),
    do: {:error, "subagent is unavailable: #{inspect(reason)}"}
end

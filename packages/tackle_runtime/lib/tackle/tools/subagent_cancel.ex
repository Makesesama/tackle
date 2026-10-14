defmodule Tackle.Tools.SubagentCancel do
  @moduledoc """
  Cancels one background subagent run by its stable run id.

  Only the logical parent that launched the run can cancel it. Cancellation is
  cooperative: the tool waits a bounded grace period for the child to stop and
  then terminates it. The cancelled run is consumed, and no completion notice is
  queued for it. A run that had already finished is collected instead, so its
  result is not lost.
  """

  use Tackle.Lib.Tool

  alias Tackle.Runtime
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.Outcome
  alias Tackle.Runtime.RunRef

  @grace_ms 5_000

  tool_name("subagent_cancel")

  description(
    "Stop a background subagent that is no longer needed and discard its work. Use the run_id " <>
      "returned by a background subagent launch. If the run already finished, its result is " <>
      "returned instead."
  )

  input do
    field(:run_id, :string, required: true, description: "Background subagent run id")
  end

  @spec run(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(%{"run_id" => run_id}, context) when is_binary(run_id) do
    with {:ok, agent_ref} <- fetch_agent_ref(context),
         {:ok, run_ref} <- RunRef.new(agent_ref.scope_id, run_id),
         {:ok, state} <- Runtime.cancel_run(agent_ref, run_ref) do
      finish(state, run_ref, agent_ref)
    else
      {:error, reason} -> {:error, unavailable(reason)}
    end
  end

  def run(_args, _context), do: {:error, "subagent_cancel requires a run_id"}

  @impl true
  def model_error(reason) when is_binary(reason), do: reason
  def model_error(_reason), do: nil

  defp fetch_agent_ref(context) do
    case AgentRef.from_context(context) do
      %AgentRef{} = agent_ref -> {:ok, agent_ref}
      nil -> {:error, "subagent cancel is unavailable: this agent has no runtime reference"}
    end
  end

  defp finish({:completed, %Outcome{} = outcome}, run_ref, _owner) do
    completed(outcome, run_ref, "had already finished before it could be cancelled")
  end

  defp finish(:cancelling, run_ref, owner) do
    case Runtime.await(owner, run_ref, @grace_ms) do
      %Outcome{status: :cancelled} ->
        {:ok, "Subagent #{run_ref.run_id} was cancelled."}

      %Outcome{status: :timeout} ->
        {:ok, "Subagent #{run_ref.run_id} did not stop in time and was terminated."}

      %Outcome{} = outcome ->
        completed(outcome, run_ref, "finished before cancellation took effect")

      # Another caller consumed the outcome first; the run has stopped either way.
      {:error, reason} when reason in [:not_found, :request_terminated] ->
        {:ok, "Subagent #{run_ref.run_id} was cancelled."}

      {:error, reason} ->
        {:error, unavailable(reason)}
    end
  end

  defp completed(%Outcome{status: :ok} = outcome, run_ref, how) do
    answer = Outcome.answer(outcome) || "(subagent produced no answer)"
    {:ok, "Subagent #{run_ref.run_id} #{how}; it completed:\n\n#{answer}"}
  end

  defp completed(%Outcome{} = outcome, run_ref, how) do
    {:ok, "Subagent #{run_ref.run_id} #{how}; it ended with #{Outcome.message(outcome)}"}
  end

  defp unavailable(reason) when reason in [:not_found, :request_terminated, :not_owner],
    do: "subagent run was not found or was already collected"

  defp unavailable({:invalid_run_id, _run_id}), do: "subagent_cancel requires a valid run_id"
  defp unavailable(message) when is_binary(message), do: message
  defp unavailable(reason), do: "subagent run is unavailable: #{inspect(reason)}"
end

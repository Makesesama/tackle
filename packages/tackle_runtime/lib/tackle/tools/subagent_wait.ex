defmodule Tackle.Tools.SubagentWait do
  @moduledoc """
  Waits for and collects one background subagent run.

  Only the logical parent that launched the run can wait for it. The run remains
  independent of the parent turn: cancelling the waiting tool does not cancel or
  consume the background work.
  """

  use Tackle.Lib.Tool

  alias Tackle.Runtime
  alias Tackle.Runtime.Handle
  alias Tackle.Runtime.Outcome
  alias Tackle.Runtime.RunRef

  tool_name("subagent_wait")

  description(
    "Wait for a background subagent to finish, then consume and return its final answer or " <>
      "failure. Use the run_id returned by a background subagent launch."
  )

  input do
    field(:run_id, :string, required: true, description: "Background subagent run id")
  end

  @spec run(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(%{"run_id" => run_id}, context) when is_binary(run_id) do
    with {:ok, handle} <- fetch_handle(context),
         {:ok, run_ref} <- RunRef.new(handle.scope_ref.scope_id, run_id) do
      wait(run_ref, handle.agent_ref)
    else
      {:error, reason} -> {:error, unavailable(reason)}
    end
  end

  def run(_args, _context), do: {:error, "subagent_wait requires a run_id"}

  @impl true
  def model_error(reason) when is_binary(reason), do: reason
  def model_error(_reason), do: nil

  defp fetch_handle(context) do
    case Handle.from_context(context) do
      %Handle{} = handle -> {:ok, handle}
      nil -> {:error, "subagent wait is unavailable: this agent has no runtime handle"}
    end
  end

  defp wait(run_ref, owner) do
    Runtime.await(owner, run_ref, :infinity)
    |> handle_outcome(run_ref)
  end

  defp handle_outcome(%Outcome{status: :ok} = outcome, run_ref) do
    answer = Outcome.answer(outcome) || "(subagent produced no answer)"
    {:ok, "Subagent #{run_ref.run_id} completed:\n\n#{answer}"}
  end

  defp handle_outcome(%Outcome{} = outcome, run_ref) do
    {:error, "Subagent #{run_ref.run_id} #{Outcome.message(outcome)}"}
  end

  defp handle_outcome({:error, reason}, _run_ref), do: {:error, unavailable(reason)}

  defp unavailable(reason) when reason in [:not_found, :request_terminated, :not_owner],
    do: "subagent run was not found or was already collected"

  defp unavailable({:invalid_run_id, _run_id}), do: "subagent_wait requires a valid run_id"
  defp unavailable(message) when is_binary(message), do: message
  defp unavailable(reason), do: "subagent run is unavailable: #{inspect(reason)}"
end

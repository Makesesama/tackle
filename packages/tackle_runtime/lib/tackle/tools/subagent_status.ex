defmodule Tackle.Tools.SubagentStatus do
  @moduledoc """
  Inspects or collects a background subagent run by its stable run id.

  Only runs launched by the calling agent can be addressed. Runtime references
  remain internal; the model sees the generated run id and a bounded result.
  """

  use Tackle.Lib.Tool

  alias Tackle.Runtime
  alias Tackle.Runtime.Handle
  alias Tackle.Runtime.Outcome
  alias Tackle.Runtime.RunRef

  tool_name("subagent_status")

  description(
    "Check a background subagent. Returns running status, or consumes and returns its final " <>
      "answer or failure. Use the run_id returned by an async subagent launch."
  )

  input do
    field(:run_id, :string, required: true, description: "Background subagent run id")
  end

  @spec run(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(%{"run_id" => run_id}, context) when is_binary(run_id) do
    with {:ok, handle} <- fetch_handle(context),
         {:ok, run_ref} <- run_ref(handle, run_id),
         :ok <- ensure_owned(handle, run_ref) do
      status(run_ref, handle.agent_ref)
    end
  end

  def run(_args, _context), do: {:error, "subagent_status requires a run_id"}

  @impl true
  def model_error(reason) when is_binary(reason), do: reason
  def model_error(_reason), do: nil

  defp fetch_handle(context) do
    case Handle.from_context(context) do
      %Handle{} = handle -> {:ok, handle}
      nil -> {:error, "subagent status is unavailable: this agent has no runtime handle"}
    end
  end

  defp run_ref(%Handle{scope_ref: scope_ref}, run_id) do
    RunRef.new(scope_ref.scope_id, run_id)
  end

  defp ensure_owned(%Handle{}, _run_ref), do: :ok

  defp status(run_ref, owner) do
    case Runtime.run_status(owner, run_ref) do
      {:ok, :running} ->
        {:ok, "Subagent #{run_ref.run_id} is still running."}

      {:ok, {:completed, %Outcome{}}} ->
        Runtime.collect(owner, run_ref) |> handle_outcome(run_ref)

      {:error, reason} ->
        {:error, unavailable(reason)}
    end
  end

  defp handle_outcome(%Outcome{status: :ok} = outcome, run_ref) do
    answer = Outcome.answer(outcome) || "(subagent produced no answer)"
    {:ok, "Subagent #{run_ref.run_id} completed:\n\n#{answer}"}
  end

  defp handle_outcome(%Outcome{} = outcome, run_ref) do
    {:error, "Subagent #{run_ref.run_id} #{Outcome.message(outcome)}"}
  end

  defp handle_outcome({:error, reason}, _run_ref), do: {:error, unavailable(reason)}

  defp unavailable(reason) when reason in [:not_found, :request_terminated],
    do: "subagent run was not found or was already collected"

  defp unavailable(reason), do: "subagent run is unavailable: #{inspect(reason)}"
end

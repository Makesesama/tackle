defmodule Tackle.Lib.Tool.Batch do
  @moduledoc false

  require Logger

  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Tool.Error

  @tool_poll_ms 100
  @tool_shutdown_ms 1_000

  # Jobs contain only the resolved execution inputs, never the agent state.
  # The caller prepares them after its before-tool hooks and commits the returned
  # settlements in call order, retaining sole ownership of the transcript.
  @spec run([map()], pid() | atom(), (map() -> term()), (term() -> term()), (-> boolean())) ::
          {map(), :ok | :cancelled}
  def run(jobs, supervisor, settle, on_execution_end, cancelled?) do
    jobs
    |> Enum.map(&start_task(&1, supervisor, settle))
    |> await(%{}, on_execution_end, cancelled?)
  end

  defp start_task(%{index: index, call: call} = job, supervisor, settle) do
    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        :proc_lib.set_label("tool:#{call.name}")
        settle.(job)
      end)

    {index, call, task}
  end

  defp await([], settlements, _on_execution_end, _cancelled?), do: {settlements, :ok}

  defp await(pending, settlements, on_execution_end, cancelled?) do
    {settlements, pending} = drain(pending, settlements, on_execution_end)

    cond do
      pending == [] -> {settlements, :ok}
      cancelled?.() -> {shutdown(pending, settlements, on_execution_end), :cancelled}
      true -> await(pending, settlements, on_execution_end, cancelled?)
    end
  end

  defp drain(pending, settlements, on_execution_end) do
    by_ref = Map.new(pending, fn {index, call, task} -> {task.ref, {index, call}} end)

    settled =
      pending
      |> Enum.map(fn {_index, _call, task} -> task end)
      |> Task.yield_many(@tool_poll_ms)

    {settlements, done_refs} =
      Enum.reduce(settled, {settlements, MapSet.new()}, fn {task, result}, {acc, done} ->
        case result do
          nil ->
            {acc, done}

          {:ok, settlement} ->
            {index, _call} = Map.fetch!(by_ref, task.ref)
            on_execution_end.(settlement)
            {Map.put(acc, index, settlement), MapSet.put(done, task.ref)}

          {:exit, reason} ->
            {index, call} = Map.fetch!(by_ref, task.ref)
            Logger.error("Tool task for #{call.name} exited: #{inspect(reason)}")

            settlement = crashed_settlement(call, reason)
            on_execution_end.(settlement)
            {Map.put(acc, index, settlement), MapSet.put(done, task.ref)}
        end
      end)

    pending =
      Enum.reject(pending, fn {_index, _call, task} ->
        MapSet.member?(done_refs, task.ref)
      end)

    {settlements, pending}
  end

  defp shutdown(pending, settlements, on_execution_end) do
    Enum.reduce(pending, settlements, fn {index, _call, task}, acc ->
      case Task.shutdown(task, @tool_shutdown_ms) do
        {:ok, settlement} ->
          on_execution_end.(settlement)
          Map.put(acc, index, settlement)

        _other ->
          acc
      end
    end)
  end

  defp crashed_settlement(%Call{} = call, reason) do
    {:error,
     %Error{
       tool_call_id: call.id,
       name: call.name,
       reason: :execution_error,
       message: "Tool crashed: #{inspect(reason)}",
       content: "Error: The tool failed while completing the request.",
       details: reason,
       metadata: %{definition_id: call.definition_id}
     }}
  end
end

defmodule Tackle.Tools.Bash do
  @moduledoc "Executes Bash commands for the agent."

  use Tackle.Lib.Tool

  alias Tackle.Executor
  alias Tackle.Lib.{Cancellation, Event}
  alias Tackle.Tools.Bash.Capture
  alias Tackle.Tools.FileSystem

  @poll_interval 50

  tool_name("bash")

  description(
    "Execute a Bash command in the current working directory and return combined stdout and stderr. " <>
      "Output is limited to the last 2,000 lines or 50KB. An optional timeout is measured in seconds."
  )

  input do
    field(:command, :string, required: true, description: "Bash command to execute")
    field(:timeout, :float, description: "Positive timeout in seconds; omitted means no timeout")
  end

  @spec run(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(%{"command" => command} = args, context) do
    timeout = Map.get(args, "timeout")

    with :ok <- validate_command(command),
         :ok <- validate_timeout(timeout),
         {:ok, cwd} <- FileSystem.resolve_path(".", context) do
      execute(Executor.from_context(context), command, cwd, timeout, context)
    end
  end

  @impl true
  def model_error(reason) when is_binary(reason), do: reason
  def model_error(_reason), do: nil

  defp validate_command(""), do: {:error, "command must not be empty"}
  defp validate_command(command) when is_binary(command), do: :ok

  defp validate_timeout(nil), do: :ok
  defp validate_timeout(timeout) when is_number(timeout) and timeout > 0, do: :ok
  defp validate_timeout(_timeout), do: {:error, "timeout must be a positive number of seconds"}

  defp execute(executor, command, cwd, timeout, context) do
    case Executor.exec(executor, ["bash", "-c", command], cwd: cwd) do
      {:ok, handle} ->
        run = %{
          executor: executor,
          handle: handle,
          deadline: deadline(timeout),
          signal: Map.get(context, :cancellation_signal),
          context: context
        }

        case collect(run, Capture.new(executor), "") do
          {:ok, status, output} -> settle(status, Capture.finish(output))
          {:error, reason, output} -> {:error, append_output(reason, Capture.finish(output))}
        end

      {:error, reason} ->
        {:error, "Could not execute command: #{Executor.format_reason(reason)}"}
    end
  end

  defp collect(run, output, pending_utf8) do
    case collect_step(run, output, pending_utf8) do
      {:continue, output, pending_utf8} -> collect(run, output, pending_utf8)
      result -> result
    end
  end

  defp collect_step(run, output, pending_utf8) do
    run.executor
    |> Executor.await(run.handle, wait_time(run.deadline))
    |> handle_event(run, output, pending_utf8)
  catch
    kind, reason ->
      Capture.discard(output)
      Executor.cancel(run.executor, run.handle)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp handle_event({:data, data}, run, output, pending_utf8) do
    {progress, pending_utf8} = split_live_utf8(pending_utf8 <> data)
    emit_progress(run.context, progress)
    continue_or_stop(run, Capture.append(output, progress), pending_utf8)
  end

  defp handle_event({:exit_status, status}, run, output, pending_utf8) do
    {:ok, status, flush_pending(run, output, pending_utf8)}
  end

  defp handle_event({:error, reason}, run, output, pending_utf8) do
    message = "Command failed: #{Executor.format_reason(reason)}"
    {:error, message, flush_pending(run, output, pending_utf8)}
  end

  defp handle_event(:timeout, run, output, pending_utf8) do
    continue_or_stop(run, output, pending_utf8)
  end

  # Checked after every event, so a busy command still honours the deadline
  # and cancellation.
  defp continue_or_stop(run, output, pending_utf8) do
    case stop_reason(run) do
      nil ->
        {:continue, output, pending_utf8}

      reason ->
        output = flush_pending(run, output, pending_utf8)
        Executor.cancel(run.executor, run.handle)
        {:error, reason, output}
    end
  end

  defp stop_reason(run) do
    cond do
      cancelled?(run.signal) -> "Command aborted"
      timed_out?(run.deadline) -> "Command timed out"
      true -> nil
    end
  end

  defp flush_pending(run, output, pending_utf8) do
    emit_progress(run.context, sanitize(pending_utf8))
    Capture.append(output, sanitize(pending_utf8))
  end

  defp split_live_utf8(data) do
    case :unicode.characters_to_binary(data, :utf8, :utf8) do
      valid when is_binary(valid) ->
        {valid, ""}

      {:incomplete, valid, rest} ->
        {valid, IO.iodata_to_binary(rest)}

      {:error, _valid, _rest} ->
        # Sanitize invalid sequences together, but keep a possibly valid trailing
        # character for the next chunk. Replacing byte-by-byte changes grouping.
        pending = incomplete_suffix(data)
        prefix = binary_part(data, 0, byte_size(data) - byte_size(pending))
        {sanitize(prefix), pending}
    end
  end

  defp incomplete_suffix(data) do
    Enum.find_value(min(byte_size(data), 3)..1//-1, "", fn size ->
      suffix = binary_part(data, byte_size(data) - size, size)

      case :unicode.characters_to_binary(suffix, :utf8, :utf8) do
        {:incomplete, "", _} -> suffix
        _ -> nil
      end
    end)
  end

  defp emit_progress(context, data) when is_binary(data) and data != "" do
    case Map.get(context, :event_callback) do
      callback when is_function(callback, 1) ->
        callback.(
          Event.new(:tool_progress, %{
            tool_call_id: Map.get(context, :tool_call_id),
            name: "bash",
            delta: sanitize(data)
          })
        )

      _other ->
        :ok
    end
  end

  defp emit_progress(_context, _data), do: :ok

  defp deadline(nil), do: :infinity

  defp deadline(timeout) do
    System.monotonic_time(:millisecond) + trunc(timeout * 1_000)
  end

  defp wait_time(:infinity), do: @poll_interval

  defp wait_time(deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    min(remaining, @poll_interval)
  end

  defp timed_out?(:infinity), do: false
  defp timed_out?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  defp cancelled?(nil), do: false
  defp cancelled?(signal), do: Cancellation.cancelled?(signal)

  defp settle(0, output), do: {:ok, output}

  defp settle(status, output) do
    {:error, append_output("Command exited with code #{status}", output)}
  end

  defp append_output(reason, "(no output)"), do: reason
  defp append_output(reason, output), do: output <> "\n\n" <> reason

  defp sanitize(output) do
    if String.valid?(output), do: output, else: String.replace_invalid(output)
  end
end

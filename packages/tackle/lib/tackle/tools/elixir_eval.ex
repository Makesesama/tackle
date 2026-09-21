defmodule Tackle.Tools.ElixirEval do
  @moduledoc "Evaluates stateless Elixir code inside the running Tackle BEAM."

  use Tackle.Lib.Tool

  alias Tackle.Lib.Cancellation
  alias Tackle.Tools.Output

  @default_timeout 5.0
  @poll_interval 50

  tool_name("elixir_eval")

  description(
    "Evaluate stateless Elixir code inside the running Tackle BEAM and return captured standard output and the inspected result. " <>
      "Explicit writes to standard error remain on Tackle's standard error device. " <>
      "The code can inspect and modify live runtime state, and its side effects persist, but bindings do not carry between calls. " <>
      "Evaluation is limited to 5 seconds by default and output is limited to the last 2,000 lines or 50KB. " <>
      "This is arbitrary code execution, not a sandbox."
  )

  input do
    field(:code, :string, required: true, description: "Elixir code to evaluate")

    field(:timeout, :float,
      default: @default_timeout,
      description: "Positive timeout in seconds (default: 5)"
    )
  end

  @spec run(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(%{"code" => code} = args, context) do
    timeout = Map.get(args, "timeout", @default_timeout)

    with :ok <- validate_code(code),
         :ok <- validate_timeout(timeout) do
      evaluate(code, timeout, Map.get(context, :cancellation_signal))
    end
  end

  defp validate_code(""), do: {:error, "code must not be empty"}
  defp validate_code(code) when is_binary(code), do: :ok

  defp validate_timeout(timeout) when is_number(timeout) and timeout > 0, do: :ok
  defp validate_timeout(_timeout), do: {:error, "timeout must be a positive number of seconds"}

  defp evaluate(code, timeout, signal) do
    if cancelled?(signal) do
      {:error, "Evaluation aborted"}
    else
      {:ok, io_device} = StringIO.open("")
      outcome = execute(code, timeout, signal, io_device)
      output = close_io(io_device)
      settle(outcome, output)
    end
  end

  defp execute(code, timeout, signal, io_device) do
    caller = self()
    tag = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        Process.group_leader(self(), io_device)
        send(caller, {tag, eval(code)})
      end)

    deadline = System.monotonic_time(:millisecond) + trunc(timeout * 1_000)
    await(pid, monitor_ref, tag, deadline, signal)
  end

  defp eval(code) do
    {value, _binding} = Code.eval_string(code, [], file: "tackle_elixir_eval", line: 1)

    {:ok,
     inspect(value,
       pretty: true,
       width: 100,
       limit: 100,
       printable_limit: Output.max_bytes()
     )}
  rescue
    error -> {:error, Exception.format(:error, error, __STACKTRACE__)}
  catch
    kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp await(pid, monitor_ref, tag, deadline, signal) do
    receive do
      {^tag, outcome} ->
        Process.demonitor(monitor_ref, [:flush])
        outcome

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, "Evaluation process exited: #{inspect(reason)}"}
    after
      wait_time(deadline) ->
        cond do
          cancelled?(signal) ->
            stop(pid, monitor_ref)
            {:error, "Evaluation aborted"}

          System.monotonic_time(:millisecond) >= deadline ->
            stop(pid, monitor_ref)
            {:error, "Evaluation timed out"}

          true ->
            await(pid, monitor_ref, tag, deadline, signal)
        end
    end
  end

  defp wait_time(deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    min(remaining, @poll_interval)
  end

  defp stop(pid, monitor_ref) do
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      1_000 -> Process.demonitor(monitor_ref, [:flush])
    end
  end

  defp cancelled?(nil), do: false
  defp cancelled?(signal), do: Cancellation.cancelled?(signal)

  defp close_io(io_device) do
    case StringIO.close(io_device) do
      {:ok, {_input, output}} -> sanitize(output)
      _other -> ""
    end
  catch
    :exit, _reason -> ""
  end

  defp settle({:ok, result}, output) do
    {:ok, format_output(output, "Result:\n" <> result)}
  end

  defp settle({:error, reason}, output) do
    {:error, format_output(output, reason)}
  end

  defp format_output("", result), do: limit_output(result)

  defp format_output(output, result) do
    limit_output("Output:\n" <> String.trim_trailing(output, "\n") <> "\n\n" <> result)
  end

  defp limit_output(content) do
    result = Output.tail(content)

    if result.truncated? do
      start_line = result.total_lines - result.output_lines + 1

      result.content <>
        "\n\n[Showing lines #{start_line}-#{result.total_lines} of #{result.total_lines}.]"
    else
      result.content
    end
  end

  defp sanitize(output) do
    if String.valid?(output), do: output, else: String.replace_invalid(output)
  end
end

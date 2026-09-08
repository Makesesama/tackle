defmodule Tackle.Tools.Bash do
  @moduledoc "Executes Bash commands for the agent."

  use Tackle.Lib.Tool

  alias Tackle.Lib.Cancellation
  alias Tackle.Tools.{FileSystem, Output}

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
         {:ok, cwd} <- FileSystem.resolve_path(".", context),
         {:ok, executable} <- find_bash() do
      execute(executable, command, cwd, timeout, Map.get(context, :cancellation_signal))
    end
  end

  defp validate_command(""), do: {:error, "command must not be empty"}
  defp validate_command(command) when is_binary(command), do: :ok

  defp validate_timeout(nil), do: :ok
  defp validate_timeout(timeout) when is_number(timeout) and timeout > 0, do: :ok
  defp validate_timeout(_timeout), do: {:error, "timeout must be a positive number of seconds"}

  defp find_bash do
    case System.find_executable("bash") do
      nil -> {:error, "Could not execute command: bash was not found on PATH"}
      executable -> {:ok, executable}
    end
  end

  defp execute(executable, command, cwd, timeout, signal) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :use_stdio,
          :hide,
          {:args, [~c"-lc", String.to_charlist(command)]},
          {:cd, String.to_charlist(cwd)}
        ]
      )

    deadline = deadline(timeout)

    case collect(port, deadline, signal, []) do
      {:ok, status, output} -> settle(status, output)
      {:error, reason, output} -> {:error, append_output(reason, format_output(output))}
    end
  rescue
    error in ErlangError ->
      {:error, "Could not execute command: #{Exception.message(error)}"}
  end

  defp collect(port, deadline, signal, output) do
    receive do
      {^port, {:data, data}} ->
        collect(port, deadline, signal, [data | output])

      {^port, {:exit_status, status}} ->
        {:ok, status, output |> Enum.reverse() |> IO.iodata_to_binary() |> sanitize()}
    after
      wait_time(deadline) ->
        cond do
          cancelled?(signal) ->
            close(port)

            {:error, "Command aborted",
             output |> Enum.reverse() |> IO.iodata_to_binary() |> sanitize()}

          timed_out?(deadline) ->
            close(port)

            {:error, "Command timed out",
             output |> Enum.reverse() |> IO.iodata_to_binary() |> sanitize()}

          true ->
            collect(port, deadline, signal, output)
        end
    end
  end

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

  defp close(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp settle(0, output), do: {:ok, format_output(output)}

  defp settle(status, output) do
    {:error, append_output("Command exited with code #{status}", format_output(output))}
  end

  defp format_output(""), do: "(no output)"

  defp format_output(output) do
    result = Output.tail(output)

    if result.truncated? do
      full_output_path = save_full_output(output)
      start_line = result.total_lines - result.output_lines + 1
      location = if full_output_path, do: " Full output: #{full_output_path}", else: ""

      result.content <>
        "\n\n[Showing lines #{start_line}-#{result.total_lines} of #{result.total_lines}.#{location}]"
    else
      result.content
    end
  end

  defp save_full_output(output) do
    path =
      Path.join(
        System.tmp_dir!(),
        "tackle-bash-#{System.unique_integer([:positive, :monotonic])}.log"
      )

    case File.write(path, output) do
      :ok -> path
      {:error, _reason} -> nil
    end
  end

  defp append_output(reason, "(no output)"), do: reason
  defp append_output(reason, output), do: output <> "\n\n" <> reason

  defp sanitize(output) do
    if String.valid?(output), do: output, else: String.replace_invalid(output)
  end
end

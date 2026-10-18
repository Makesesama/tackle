# Compiled inside each project node by the broker (`Code.compile_file/1`), so
# it runs with the project's own Elixir and OTP. Keep it free of dependencies
# and of Elixir APIs newer than 1.15.

defmodule TackleProjectNode.Helper do
  @moduledoc false

  @max_output 65_536
  @max_diagnostics 1_000
  @max_message 4_000
  # All diagnostic messages together, so a reply fits the host's frame limit.
  @max_messages_total 2_000_000
  @severities [:error, :warning, :information, :hint]

  @doc """
  Loads the Mix project in the current directory without compiling it or
  starting it, and halts this node when the broker goes away.
  """
  def boot(broker) do
    watch(broker)

    case capture(fn -> Mix.CLI.main(["loadpaths", "--no-compile", "--no-deps-check"]) end) do
      {:ok, _result, output} ->
        if Mix.Project.get(),
          do: :ok,
          else: {:error, truncate("no mix.exs in #{File.cwd!()}\n" <> output, @max_message)}

      {:error, message, output} ->
        {:error, truncate(message <> "\n" <> output, @max_message)}
    end
  end

  defp watch(broker) do
    spawn(fn ->
      Node.monitor(broker, true)

      receive do
        {:nodedown, ^broker} -> System.halt(0)
      end
    end)

    :ok
  end

  @doc """
  Compiles the project, returning `{:ok, %{status, diagnostics, output,
  duration_ms}}` with the diagnostics of every file, including warnings of
  files that were not recompiled.
  """
  def compile do
    started = System.monotonic_time(:millisecond)

    run = fn ->
      Mix.Task.clear()
      Mix.Task.run("compile", ["--return-errors", "--all-warnings"])
    end

    case capture(run) do
      {:ok, result, output} ->
        compiled(result(result), output, started)

      {:error, message, output} ->
        {:error, truncate(message <> "\n" <> tail(output), @max_message)}
    end
  end

  defp compiled({:unexpected, message}, output, _started),
    do: {:error, truncate(message <> "\n" <> tail(output), @max_message)}

  defp compiled({status, diagnostics}, output, started) do
    {:ok,
     %{
       status: status,
       diagnostics:
         diagnostics |> Enum.take(@max_diagnostics) |> Enum.map(&diagnostic/1) |> budget(),
       output: tail(output),
       duration_ms: System.monotonic_time(:millisecond) - started
     }}
  end

  defp budget(diagnostics) do
    {kept, _left} =
      Enum.reduce(diagnostics, {[], @max_messages_total}, fn diagnostic, {kept, left} ->
        size = byte_size(diagnostic.message)
        if size <= left, do: {[diagnostic | kept], left - size}, else: {kept, 0}
      end)

    Enum.reverse(kept)
  end

  defp result({status, diagnostics}) when status in [:ok, :error, :noop] and is_list(diagnostics),
    do: {status, diagnostics}

  defp result(status) when status in [:ok, :error, :noop], do: {status, []}

  defp result(other),
    do: {:unexpected, "unexpected compile result: " <> inspect(other, limit: 20)}

  defp diagnostic(diagnostic) do
    {line, column} = position(Map.get(diagnostic, :position))

    %{
      severity: severity(Map.get(diagnostic, :severity)),
      file: path(Map.get(diagnostic, :file)),
      line: line,
      column: column,
      message: diagnostic |> Map.get(:message) |> message(),
      compiler: diagnostic |> Map.get(:compiler_name) |> compiler()
    }
  end

  defp severity(severity) when severity in @severities, do: severity
  defp severity(_severity), do: :warning

  defp path(file) when is_binary(file), do: Path.expand(file)
  defp path(_file), do: nil

  defp position(line) when is_integer(line) and line > 0, do: {line, nil}

  defp position({line, column}) when is_integer(line) and line > 0 and is_integer(column),
    do: {line, column}

  defp position({line, column, _end_line, _end_column}) when is_integer(line) and line > 0,
    do: {line, if(is_integer(column), do: column, else: nil)}

  defp position(_position), do: {nil, nil}

  defp message(message) when is_binary(message), do: truncate(message, @max_message)

  defp message(message) do
    message |> IO.chardata_to_string() |> truncate(@max_message)
  rescue
    _error -> "(unprintable message)"
  end

  defp compiler(name) when is_binary(name), do: truncate(name, 100)
  defp compiler(_name), do: nil

  # Mix prints through the group leader; capture it so nothing reaches the
  # broker's frames, and return it with the result.
  defp capture(fun) do
    {:ok, device} = StringIO.open("")
    previous = Process.group_leader()
    Process.group_leader(self(), device)

    try do
      result = fun.()
      {:ok, result, output(device)}
    catch
      kind, reason ->
        {:error, Exception.format_banner(kind, reason, __STACKTRACE__), output(device)}
    after
      Process.group_leader(self(), previous)
      StringIO.close(device)
    end
  end

  defp output(device) do
    {_input, output} = StringIO.contents(device)
    output
  end

  defp tail(output) when byte_size(output) <= @max_output, do: output
  defp tail(output), do: binary_part(output, byte_size(output) - @max_output, @max_output)

  defp truncate(binary, max) when byte_size(binary) <= max, do: binary
  defp truncate(binary, max), do: binary_part(binary, 0, max)
end

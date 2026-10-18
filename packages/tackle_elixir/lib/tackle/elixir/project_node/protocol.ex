defmodule Tackle.Elixir.ProjectNode.Protocol do
  @moduledoc """
  Frames between the host and the project node broker.

  Every frame is one Erlang external term with a 4-byte length prefix. The
  broker (`priv/project_node/broker.exs`) sends `{:hello, version}` first and
  then one reply per request:

      # host -> broker
      {:request, id, {:compile, root}}

      # broker -> host
      {:hello, 1}
      {:reply, id, {:ok, result}}
      {:reply, id, {:error, message}}

  The broker runs project code, so everything it sends is untrusted. Frames
  are decoded with `Tackle.Exec.Protocol.decode/1` (no compressed terms, no
  new atoms, no trailing bytes), and `parse_message/1` and `parse_result/2`
  accept only the shapes above with every field checked and bounded.
  """

  alias Tackle.Elixir.Diagnostic

  @version 1
  @max_error_bytes 8_192
  @max_output_bytes 65_536
  @max_message_bytes 4_000
  @max_diagnostics 1_000
  @max_path_bytes 4_096
  @max_compiler_bytes 100
  @max_duration_ms 24 * 60 * 60 * 1_000
  @statuses [:ok, :error, :noop]
  @severities [:error, :warning, :information, :hint]
  @diagnostic_keys [:column, :compiler, :file, :line, :message, :severity]

  @typedoc "Requests the host sends."
  @type request :: {:compile, Path.t()}

  @typedoc "The result of a `:compile` request."
  @type compile_result :: %{
          status: :ok | :error | :noop,
          diagnostics: [Diagnostic.t()],
          output: String.t(),
          duration_ms: non_neg_integer()
        }

  @doc "Returns the protocol version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Encodes a request as a length-prefixed frame."
  @spec encode_request(pos_integer(), request()) :: binary()
  def encode_request(id, {:compile, root} = request)
      when is_integer(id) and id > 0 and is_binary(root) do
    Tackle.Exec.Protocol.encode_frame({:request, id, request})
  end

  @doc "Decodes one untrusted frame."
  @spec decode(binary()) :: {:ok, term()} | {:error, atom()}
  def decode(frame), do: Tackle.Exec.Protocol.decode(frame)

  @doc "Validates a message from the broker."
  @spec parse_message(term()) ::
          {:ok, {:hello, integer()} | {:reply, pos_integer(), {:ok, term()} | {:error, binary()}}}
          | {:error, :invalid_message}
  def parse_message({:hello, version} = message) when is_integer(version), do: {:ok, message}

  def parse_message({:reply, id, {:ok, _result}} = message) when is_integer(id) and id > 0,
    do: {:ok, message}

  def parse_message({:reply, id, {:error, reason}} = message)
      when is_integer(id) and id > 0 and is_binary(reason) and
             byte_size(reason) <= @max_error_bytes,
      do: {:ok, message}

  def parse_message(_term), do: {:error, :invalid_message}

  @doc "Validates the result of a successful request and converts it."
  @spec parse_result(request(), term()) :: {:ok, compile_result()} | {:error, :invalid_result}
  def parse_result(
        {:compile, _root},
        %{status: status, diagnostics: diagnostics, output: output, duration_ms: duration} =
          result
      )
      when map_size(result) == 4 and status in @statuses and is_list(diagnostics) and
             is_binary(output) and byte_size(output) <= @max_output_bytes and
             is_integer(duration) and duration in 0..@max_duration_ms do
    with true <- length(diagnostics) <= @max_diagnostics,
         {:ok, diagnostics} <- parse_diagnostics(diagnostics) do
      {:ok, %{result | diagnostics: diagnostics, output: printable(output)}}
    else
      _invalid -> {:error, :invalid_result}
    end
  end

  def parse_result(_request, _result), do: {:error, :invalid_result}

  defp parse_diagnostics(diagnostics) do
    Enum.reduce_while(diagnostics, {:ok, []}, fn diagnostic, {:ok, acc} ->
      case parse_diagnostic(diagnostic) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      :error -> :error
    end
  end

  defp parse_diagnostic(%{severity: severity, message: message} = diagnostic)
       when severity in @severities and is_binary(message) and
              byte_size(message) <= @max_message_bytes do
    if Map.keys(diagnostic) |> Enum.sort() == @diagnostic_keys and
         optional_path?(diagnostic.file) and optional_position?(diagnostic.line) and
         optional_position?(diagnostic.column) and optional_compiler?(diagnostic.compiler) do
      {:ok,
       %Diagnostic{
         severity: severity,
         file: diagnostic.file,
         line: diagnostic.line,
         column: diagnostic.column,
         message: printable(message),
         compiler: diagnostic.compiler && printable(diagnostic.compiler)
       }}
    else
      :error
    end
  end

  defp parse_diagnostic(_diagnostic), do: :error

  defp optional_path?(nil), do: true

  defp optional_path?(path),
    do:
      is_binary(path) and byte_size(path) <= @max_path_bytes and Path.type(path) == :absolute and
        not String.contains?(path, <<0>>)

  defp optional_position?(nil), do: true
  defp optional_position?(value), do: is_integer(value) and value in 0..100_000_000

  defp optional_compiler?(nil), do: true
  defp optional_compiler?(name), do: is_binary(name) and byte_size(name) <= @max_compiler_bytes

  defp printable(text), do: if(String.valid?(text), do: text, else: String.replace_invalid(text))
end

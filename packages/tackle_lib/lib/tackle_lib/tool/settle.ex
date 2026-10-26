defmodule Tackle.Lib.Tool.Settle do
  @moduledoc false

  # The local tool pipeline behind `Tackle.Lib.Tool.settle/3`. Each stage
  # returns `{:ok, value}` or an error tagged with the stage that failed:
  #
  #   * `{:invalid_input, message}`: unusable provider arguments or arguments
  #     that fail the input schema; the tool does not run;
  #   * `{:execution, reason}`: the tool returned `{:error, reason}`;
  #   * `{:crashed, kind, reason}`: the tool raised, threw, or exited;
  #   * `{:invalid_output, reason}`: the result failed the output schema or
  #     could not be projected into the transcript.
  #
  # `settle/3` turns the tag into the matching `Tackle.Lib.Tool.Error`.

  require Logger

  alias Tackle.Lib.Tool
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Tool.Content
  alias Tackle.Lib.Tool.Error
  alias Tackle.Lib.Tool.Result
  alias Tackle.Lib.Tool.Schema

  @spec settle(module(), Call.t(), map()) :: {:ok, Result.t()} | {:error, Error.t()}
  def settle(tool_module, %Call{} = call, context) do
    with {:ok, args} <- validate_input(tool_module, call),
         {:ok, raw_result} <- execute(tool_module, args, context),
         {:ok, output} <- validate_output(tool_module, raw_result),
         {:ok, {content, parts}} <- project_output(output) do
      {:ok,
       %Result{
         tool_call_id: call.id,
         name: call.name,
         raw: raw_result,
         output: output,
         content: content,
         parts: parts
       }}
    else
      {:error, {:invalid_input, message}} -> {:error, Error.invalid_input(call, message)}
      {:error, {:execution, reason}} -> {:error, Error.failed(call, reason)}
      {:error, {:crashed, kind, reason}} -> {:error, Error.crashed(call, kind, reason)}
      {:error, {:invalid_output, reason}} -> {:error, Error.invalid_output(call, reason)}
    end
  end

  defp validate_input(_tool_module, %Call{argument_error: :invalid_json}),
    do: {:error, {:invalid_input, "Invalid tool arguments: arguments are not valid JSON"}}

  defp validate_input(_tool_module, %Call{argument_error: :not_an_object}),
    do: {:error, {:invalid_input, "Invalid tool arguments: arguments must be a JSON object"}}

  defp validate_input(tool_module, %Call{arguments: arguments}) do
    case Tool.validate_args(tool_module, arguments) do
      {:ok, args} -> {:ok, args}
      {:error, message} -> {:error, {:invalid_input, message}}
    end
  end

  defp execute(tool_module, args, context) do
    case tool_module.execute(args, context) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:execution, reason}}
    end
  catch
    # A raise, an exit (such as a GenServer.call timeout), or a throw from a
    # tool is a failed execution, not a crash of the caller.
    kind, reason ->
      stacktrace = __STACKTRACE__

      Logger.error(fn ->
        ["Tool ", inspect(tool_module), " failed: ", Exception.format(kind, reason, stacktrace)]
      end)

      {:error, {:crashed, kind, reason}}
  end

  defp validate_output(_tool_module, %Content{} = content), do: {:ok, content}

  defp validate_output(tool_module, result) do
    case Tool.output_schema(tool_module) do
      nil ->
        {:ok, result}

      schema ->
        case Schema.validate_output(schema, result) do
          {:ok, output} -> {:ok, output}
          {:error, reason} -> {:error, {:invalid_output, reason}}
        end
    end
  end

  defp project_output(%Content{text: text}) when not is_binary(text),
    do: {:error, {:invalid_output, "Tool content text must be a string, got: #{inspect(text)}"}}

  defp project_output(%Content{text: text, parts: parts}) do
    case Content.validate(parts) do
      :ok -> {:ok, {model_text(text), Enum.map(parts, &sanitize_part/1)}}
      {:error, reason} -> {:error, {:invalid_output, reason}}
    end
  end

  defp project_output(result) do
    {:ok, {result |> format_result() |> model_text(), []}}
  rescue
    error ->
      {:error,
       {:invalid_output, "Tool result could not be encoded as JSON: #{Exception.message(error)}"}}
  end

  defp format_result(result) when is_map(result) or is_list(result), do: JSON.encode!(result)
  defp format_result(result) when is_binary(result), do: result
  defp format_result(result), do: inspect(result)

  # Transcript text is sent to providers as JSON on every later request, so
  # it must be valid UTF-8.
  defp model_text(text), do: String.replace_invalid(text)

  defp sanitize_part(%{"type" => "text", "text" => text} = part),
    do: %{part | "text" => model_text(text)}

  defp sanitize_part(part), do: part
end

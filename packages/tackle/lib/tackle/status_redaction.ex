defmodule Tackle.StatusRedaction do
  @moduledoc false

  # Shared by the `format_status/1` callbacks of processes that hold
  # conversation data (transcripts, tool arguments, command output) or
  # options that may carry the environment or credentials. Crash reports and
  # `:sys.get_status/1` then show a process's shape and operations, never its
  # payloads.

  @doc """
  Redacts a `:gen_server` status map: the state through `redact_state`, the
  last message to its operation, and the debug log to its length.
  """
  @spec format_status(map(), (term() -> term())) :: map()
  def format_status(status, redact_state) when is_map(status) do
    status
    |> Map.replace_lazy(:state, redact_state)
    |> Map.replace_lazy(:message, &message/1)
    |> Map.replace_lazy(:log, &{:redacted, length(&1)})
  end

  @doc "Reduces a received message to the operation it requests."
  @spec message(term()) :: term()
  def message({:"$gen_call", from, request}), do: {:"$gen_call", from, operation(request)}
  def message({:"$gen_cast", request}), do: {:"$gen_cast", operation(request)}
  def message(message), do: operation(message)

  @doc "Reduces a keyword list or map of options to its keys."
  @spec keys(term()) :: term()
  def keys(opts) when is_list(opts), do: Enum.map(opts, &key/1)
  def keys(opts) when is_map(opts), do: Map.keys(opts)
  def keys(opts), do: opts

  # One level of nesting keeps wrapped requests such as `{:request, {:append_message, ...}}`
  # recognizable.
  defp operation(operation) when is_atom(operation), do: operation

  defp operation({tag, inner}) when is_atom(tag) and is_tuple(inner) and tuple_size(inner) > 0 do
    case elem(inner, 0) do
      inner_tag when is_atom(inner_tag) -> {tag, inner_tag}
      _other -> tag
    end
  end

  defp operation({tag, inner}) when is_atom(tag) and is_atom(inner), do: {tag, inner}

  defp operation(message) when is_tuple(message) and is_atom(elem(message, 0)),
    do: elem(message, 0)

  defp operation(_message), do: :redacted

  defp key({key, _value}), do: key
  defp key(_entry), do: :redacted
end

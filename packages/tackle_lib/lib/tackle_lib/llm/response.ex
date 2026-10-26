defmodule Tackle.Lib.LLM.Response do
  @moduledoc """
  One chat turn's provider response, normalized.

  Adapters return a plain result map from `generate/2` or `stream/3` (see
  `Tackle.Lib.LLM`). `Tackle.Lib.LLM.generate_with/3` and `stream_with/4`
  keep returning that map, since they also serve structured outputs; the
  agent loop turns it into this struct with `from_result/1` before anything
  else sees it, so hooks, events, and messages read one checked shape:

    * `:content` - the assistant's text, or `nil`;
    * `:thinking` - the assistant's reasoning text, or `nil`;
    * `:tool_calls` - the provider-native tool calls as `Tackle.Lib.Tool.Call`
      structs, in provider order (possibly without ids yet; the loop assigns
      missing ones);
    * `:usage` - the response's `Tackle.Lib.Usage`, or `nil`;
    * `:model`, `:provider`, `:provider_state` - passed through from the
      result.

  ## Accepted result shape

  `from_result/1` expects `%{data: data}` with a map `data`:

    * `"content"` and `"thinking"` must be strings or absent (`nil`). The
      atom keys `:content` and `:thinking` are accepted too, like
      `:tool_calls`; a string key with a non-nil value wins.
    * `"tool_calls"` (or `:tool_calls`) must be a list of calls that
      `Tackle.Lib.Tool.Call.normalize/1` accepts; absent or `nil` means no
      tool calls.

  The result's `:usage` may be `nil`, a `Tackle.Lib.Usage`, or a provider usage
  map (normalized with `Tackle.Lib.Usage.normalize/1`), and `:provider_state`
  must be a map or `nil`. Anything else is an `{:invalid_response, detail}`
  error, where `detail` names the offending field.
  """

  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Usage

  @type t :: %__MODULE__{
          content: String.t() | nil,
          thinking: String.t() | nil,
          tool_calls: [Call.t()],
          usage: Usage.t() | nil,
          model: String.t() | nil,
          provider: String.t() | atom() | nil,
          provider_state: map() | nil
        }

  @typedoc """
  Why a result is not a valid response: the field and the offending value,
  or, for tool calls, the `Tackle.Lib.Tool.Call.normalize/1` error (or
  `:not_a_list`).
  """
  @type invalid_detail ::
          {:result, term()}
          | {:data, term()}
          | {:content, term()}
          | {:thinking, term()}
          | {:tool_calls, :malformed_tool_call | :invalid_tool_arguments | :not_a_list}
          | {:usage, term()}
          | {:provider_state, term()}

  defstruct content: nil,
            thinking: nil,
            tool_calls: [],
            usage: nil,
            model: nil,
            provider: nil,
            provider_state: nil

  @doc """
  Normalizes an adapter result map into a response.

  Returns `{:error, {:invalid_response, detail}}` for a result that does not
  have the shape described in the module docs.

      iex> {:ok, response} =
      ...>   Tackle.Lib.LLM.Response.from_result(%{data: %{"content" => "Hi"}, usage: nil})
      iex> response.content
      "Hi"

      iex> Tackle.Lib.LLM.Response.from_result(%{data: %{"content" => 42}})
      {:error, {:invalid_response, {:content, 42}}}
  """
  @spec from_result(term()) :: {:ok, t()} | {:error, {:invalid_response, invalid_detail()}}
  def from_result(%{data: data} = result) when is_map(data) do
    with {:ok, content} <- text(data, "content", :content),
         {:ok, thinking} <- text(data, "thinking", :thinking),
         {:ok, tool_calls} <- tool_calls(data),
         {:ok, usage} <- usage(Map.get(result, :usage)),
         {:ok, provider_state} <- provider_state(Map.get(result, :provider_state)) do
      {:ok,
       %__MODULE__{
         content: content,
         thinking: thinking,
         tool_calls: tool_calls,
         usage: usage,
         model: Map.get(result, :model),
         provider: Map.get(result, :provider),
         provider_state: provider_state
       }}
    end
  end

  def from_result(%{} = result), do: invalid({:data, Map.get(result, :data)})
  def from_result(result), do: invalid({:result, result})

  @doc """
  Returns true when the response has neither content (`nil` or `""`) nor
  tool calls.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{content: content, tool_calls: []}), do: content in [nil, ""]
  def empty?(%__MODULE__{}), do: false

  defp text(data, string_key, atom_key) do
    case field(data, string_key, atom_key) do
      value when is_binary(value) or is_nil(value) -> {:ok, value}
      value -> invalid({atom_key, value})
    end
  end

  defp tool_calls(data) do
    case field(data, "tool_calls", :tool_calls) do
      nil -> {:ok, []}
      calls when is_list(calls) -> normalize_calls(calls, [])
      _calls -> invalid({:tool_calls, :not_a_list})
    end
  end

  defp normalize_calls([], calls), do: {:ok, Enum.reverse(calls)}

  defp normalize_calls([raw | rest], calls) do
    case Call.normalize(raw) do
      {:ok, call} -> normalize_calls(rest, [call | calls])
      {:error, reason} -> invalid({:tool_calls, reason})
    end
  end

  defp usage(nil), do: {:ok, nil}
  defp usage(%Usage{} = usage), do: {:ok, usage}
  defp usage(%{} = usage), do: {:ok, Usage.normalize(usage)}
  defp usage(usage), do: invalid({:usage, usage})

  defp provider_state(state) when is_map(state) or is_nil(state), do: {:ok, state}
  defp provider_state(state), do: invalid({:provider_state, state})

  defp field(data, string_key, atom_key) do
    case Map.fetch(data, string_key) do
      {:ok, value} when not is_nil(value) -> value
      _absent -> Map.get(data, atom_key)
    end
  end

  defp invalid(detail), do: {:error, {:invalid_response, detail}}
end

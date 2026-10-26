defmodule Tackle.Plugins.Anthropic.Convert do
  @moduledoc false

  # Lowers provider-neutral Tackle messages and tool definitions into the
  # Anthropic Messages wire format, including Claude Code tool-name namespacing
  # and the tool_use/tool_result pairing the API requires.

  alias Tackle.Plugins.Anthropic.{Images, Prompt}

  @claude_code_tools %{
    "read" => "Read",
    "write" => "Write",
    "edit" => "Edit",
    "bash" => "Bash",
    "grep" => "Grep",
    "glob" => "Glob",
    "askuserquestion" => "AskUserQuestion",
    "todowrite" => "TodoWrite",
    "webfetch" => "WebFetch",
    "websearch" => "WebSearch"
  }
  @mcp_tool_prefix "mcp__tackle__"

  @type state :: %{
          params: [map()],
          pending: [String.t()],
          tool_ids: %{optional(String.t()) => String.t()},
          used_ids: MapSet.t(String.t()),
          is_oauth: boolean(),
          error: term()
        }

  @doc """
  Converts provider-neutral structured messages into Anthropic message params.

  Anthropic requires every `tool_use` block to be immediately followed by a user
  message containing its matching `tool_result`. Orphan tool calls (for example
  after an aborted turn) are closed with a synthetic `"No result provided"`
  result, and consecutive tool results are merged into one user message.

  Images that would exceed Anthropic's per-request image limits are replaced
  with explanatory text so a session holding them keeps working (see
  `Tackle.Plugins.Anthropic.Images`).

  Stored `provider_state` blocks are replayed only when they came from the same
  auth mode; `Tackle.Lib.LLM` passes only the provider state this provider and
  model produced.
  """
  @spec messages([map()], boolean()) :: {:ok, [map()]} | {:error, term()}
  def messages(messages, is_oauth) when is_list(messages) do
    state = %{
      params: [],
      pending: [],
      tool_ids: %{},
      used_ids: MapSet.new(),
      is_oauth: is_oauth,
      error: nil
    }

    state = convert_list(messages, state)

    case state.error do
      nil -> {:ok, state.params |> Enum.reverse() |> Images.fit_limits() |> put_cache_control()}
      error -> {:error, error}
    end
  end

  @doc "Converts provider-neutral tool definitions into Anthropic `tools` entries."
  @spec tools([map()], boolean()) :: {:ok, [map()]} | {:error, term()}
  def tools(tools, is_oauth) when is_list(tools) do
    tools
    |> Enum.reduce_while({:ok, []}, fn tool, {:ok, converted} ->
      case convert_tool(tool, is_oauth) do
        {:ok, entry} -> {:cont, {:ok, [entry | converted]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      error -> error
    end
  end

  def tools(_tools, _is_oauth), do: {:error, :invalid_tools}

  @doc "Builds a wire-name to original-name map for decoding streamed tool calls."
  @spec tool_name_map([map()], boolean()) :: %{optional(String.t()) => String.t()}
  def tool_name_map(tools, is_oauth) when is_list(tools) do
    tools
    |> Enum.flat_map(fn tool ->
      case field(tool, :name) do
        name when is_binary(name) and name != "" -> [{wire_name(name, is_oauth), name}]
        _missing -> []
      end
    end)
    |> Map.new()
  end

  def tool_name_map(_tools, _is_oauth), do: %{}

  @doc "Returns the Claude Code wire name for a Tackle tool name."
  @spec to_claude_code_tool_name(String.t()) :: String.t()
  def to_claude_code_tool_name(name) when is_binary(name) do
    Map.get(@claude_code_tools, String.downcase(name)) ||
      @mcp_tool_prefix <> sanitize_tool_name(name)
  end

  @doc "Reverses the Claude Code wire name using the offered tool definitions."
  @spec from_claude_code_tool_name(String.t(), [map()]) :: String.t()
  def from_claude_code_tool_name(name, tools) when is_binary(name) do
    if String.starts_with?(name, @mcp_tool_prefix) do
      stripped = String.replace_prefix(name, @mcp_tool_prefix, "")

      case Enum.find(tools, &(sanitize_tool_name(field(&1, :name)) == stripped)) do
        nil -> stripped
        tool -> field(tool, :name)
      end
    else
      lower = String.downcase(name)

      case Enum.find(tools, &(String.downcase(to_string(field(&1, :name))) == lower)) do
        nil -> name
        tool -> field(tool, :name)
      end
    end
  end

  defp convert_list([], state), do: state

  defp convert_list([message | rest], state) do
    case normalize_role(field(message, :role)) do
      :user -> convert_list(rest, user_message(message, flush_pending(state)))
      :assistant -> convert_list(rest, assistant_message(message, flush_pending(state)))
      :tool -> convert_tool_run(message, rest, state)
      other -> %{state | error: {:unsupported_message_role, other}}
    end
  end

  defp user_message(message, state) do
    case user_content(field(message, :content)) do
      {:ok, nil} -> state
      {:ok, content} -> push(state, %{"role" => "user", "content" => content})
      {:error, reason} -> %{state | error: reason}
    end
  end

  defp assistant_message(message, state) do
    case assistant_blocks(message, state) do
      {:ok, [], [], state} ->
        state

      {:ok, blocks, ids, state} ->
        state = push(state, %{"role" => "assistant", "content" => blocks})
        %{state | pending: ids}

      {:error, reason} ->
        %{state | error: reason}
    end
  end

  defp convert_tool_run(message, rest, state) do
    {run, rest} =
      Enum.split_while([message | rest], &(normalize_role(field(&1, :role)) == :tool))

    {results, satisfied, state} = build_tool_results(run, state)

    if state.error do
      state
    else
      synthetic =
        state.pending
        |> Enum.reject(&MapSet.member?(satisfied, &1))
        |> Enum.map(&synthetic_result/1)

      state = push(%{state | pending: []}, %{"role" => "user", "content" => results ++ synthetic})
      convert_list(rest, state)
    end
  end

  defp build_tool_results(run, state) do
    {results, satisfied, state} =
      Enum.reduce(run, {[], MapSet.new(), state}, fn message, {results, satisfied, state} ->
        if state.error do
          {results, satisfied, state}
        else
          neutral_id = field(message, :tool_call_id)

          if is_binary(neutral_id) and neutral_id != "" do
            {anthropic_id, state} = get_tool_id(state, neutral_id)
            is_error = field(message, :is_error) == true

            block =
              %{
                "type" => "tool_result",
                "tool_use_id" => anthropic_id,
                "content" => tool_result_content(field(message, :content))
              }
              |> maybe_put("is_error", is_error || nil)

            {[block | results], MapSet.put(satisfied, anthropic_id), state}
          else
            {results, satisfied, %{state | error: :invalid_tool_message}}
          end
        end
      end)

    {Enum.reverse(results), satisfied, state}
  end

  defp assistant_blocks(message, state) do
    provider_state = field(message, :provider_state)

    if replayable?(provider_state, state) do
      blocks =
        provider_state |> field(:content_blocks) |> List.wrap() |> Enum.map(&sanitize_block/1)

      ids = for %{"type" => "tool_use", "id" => id} <- blocks, is_binary(id), do: id
      {:ok, blocks, ids, state}
    else
      synthesize_blocks(message, state)
    end
  end

  defp replayable?(provider_state, state) when is_map(provider_state) do
    field(provider_state, :oauth) == state.is_oauth and
      is_list(field(provider_state, :content_blocks))
  end

  defp replayable?(_provider_state, _state), do: false

  defp synthesize_blocks(message, state) do
    content = field(message, :content)
    tool_calls = field(message, :tool_calls) |> List.wrap()

    text_blocks =
      case content do
        content when is_binary(content) ->
          case String.trim(content) do
            "" -> []
            _ -> [%{"type" => "text", "text" => Prompt.sanitize_surrogates(content)}]
          end

        _other ->
          []
      end

    case synthesize_tool_blocks(tool_calls, state) do
      {:ok, tool_blocks, ids, state} -> {:ok, text_blocks ++ tool_blocks, ids, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp synthesize_tool_blocks(tool_calls, state) do
    Enum.reduce_while(tool_calls, {:ok, [], [], state}, fn call, {:ok, blocks, ids, state} ->
      case synthesize_tool_block(call, state) do
        {:ok, block, state} -> {:cont, {:ok, [block | blocks], [block["id"] | ids], state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, blocks, ids, state} -> {:ok, Enum.reverse(blocks), Enum.reverse(ids), state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp synthesize_tool_block(call, state) do
    function = field(call, :function) || %{}
    neutral_id = field(call, :id) || field(function, :id) || "tool"
    name = field(call, :name) || field(function, :name)
    arguments = field(call, :arguments) || field(function, :arguments) || %{}

    with true <- is_binary(name) and name != "",
         {:ok, input} <- decode_arguments(arguments) do
      {anthropic_id, state} = get_tool_id(state, neutral_id)

      block = %{
        "type" => "tool_use",
        "id" => anthropic_id,
        "name" => wire_name(name, state.is_oauth),
        "input" => input
      }

      {:ok, block, state}
    else
      _invalid -> {:error, :invalid_tool_call}
    end
  end

  defp get_tool_id(state, neutral_id) do
    case Map.get(state.tool_ids, neutral_id) do
      nil ->
        candidate = unique_id(sanitize_id(neutral_id), state.used_ids, 1)

        state = %{
          state
          | tool_ids: Map.put(state.tool_ids, neutral_id, candidate),
            used_ids: MapSet.put(state.used_ids, candidate)
        }

        {candidate, state}

      existing ->
        {existing, state}
    end
  end

  defp unique_id(base, used, suffix) do
    candidate = if suffix == 1, do: base, else: "#{base}_#{suffix}"

    if MapSet.member?(used, candidate),
      do: unique_id(base, used, suffix + 1),
      else: candidate
  end

  defp flush_pending(%{pending: []} = state), do: state

  defp flush_pending(state) do
    content = Enum.map(state.pending, &synthetic_result/1)
    push(%{state | pending: []}, %{"role" => "user", "content" => content})
  end

  defp synthetic_result(id) do
    %{
      "type" => "tool_result",
      "tool_use_id" => id,
      "content" => "No result provided",
      "is_error" => true
    }
  end

  defp push(state, param), do: %{state | params: [param | state.params]}

  defp put_cache_control(params) do
    case List.last(params) do
      %{"role" => "user", "content" => [_ | _] = blocks} = last ->
        updated =
          List.update_at(blocks, -1, &Map.put(&1, "cache_control", %{"type" => "ephemeral"}))

        List.replace_at(params, -1, %{last | "content" => updated})

      _other ->
        params
    end
  end

  defp sanitize_block(%{"type" => "text", "text" => text} = block) when is_binary(text) do
    %{block | "text" => Prompt.sanitize_surrogates(text)}
  end

  defp sanitize_block(%{"type" => "thinking", "thinking" => thinking} = block)
       when is_binary(thinking) do
    %{block | "thinking" => Prompt.sanitize_surrogates(thinking)}
  end

  defp sanitize_block(block), do: block

  defp user_content(content) when is_binary(content) do
    case String.trim(content) do
      "" -> {:ok, nil}
      _ -> {:ok, Prompt.sanitize_surrogates(content)}
    end
  end

  defp user_content(parts) when is_list(parts) do
    case parts |> Enum.map(&content_block/1) |> Enum.reject(&is_nil/1) do
      [] -> {:ok, nil}
      blocks -> {:ok, blocks}
    end
  end

  defp user_content(nil), do: {:ok, nil}
  defp user_content(_content), do: {:error, :invalid_message_content}

  defp content_block(%{"type" => "text", "text" => text}) when is_binary(text) do
    if String.trim(text) == "",
      do: nil,
      else: %{"type" => "text", "text" => Prompt.sanitize_surrogates(text)}
  end

  defp content_block(%{"type" => "image", "media_type" => media_type, "data" => data})
       when is_binary(media_type) and is_binary(data) do
    %{
      "type" => "image",
      "source" => %{"type" => "base64", "media_type" => media_type, "data" => data}
    }
  end

  defp content_block(_part), do: nil

  defp tool_result_content(content) when is_binary(content),
    do: Prompt.sanitize_surrogates(content)

  defp tool_result_content(parts) when is_list(parts) do
    blocks = parts |> Enum.map(&content_block/1) |> Enum.reject(&is_nil/1)

    cond do
      not Enum.any?(blocks, &(&1["type"] == "image")) ->
        Enum.map_join(blocks, "\n", &Map.get(&1, "text", ""))

      Enum.any?(blocks, &(&1["type"] == "text")) ->
        blocks

      true ->
        [%{"type" => "text", "text" => "(see attached image)"} | blocks]
    end
  end

  defp tool_result_content(_content), do: ""

  defp convert_tool(tool, is_oauth) when is_map(tool) do
    name = field(tool, :name)
    description = field(tool, :description)
    input_schema = field(tool, :input_schema)

    if is_binary(name) and name != "" and is_binary(description) and is_map(input_schema) do
      {:ok,
       %{
         "name" => wire_name(name, is_oauth),
         "description" => description,
         "input_schema" => input_schema
       }}
    else
      {:error, {:invalid_tool, name}}
    end
  end

  defp convert_tool(_tool, _is_oauth), do: {:error, :invalid_tool}

  defp decode_arguments(arguments) when is_binary(arguments) do
    case JSON.decode(arguments) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _other} -> {:error, :tool_call_arguments_not_an_object}
      {:error, _reason} -> {:error, :invalid_tool_call_arguments}
    end
  end

  defp decode_arguments(arguments) when is_map(arguments), do: {:ok, arguments}
  defp decode_arguments(_arguments), do: {:error, :invalid_tool_call_arguments}

  defp wire_name(name, true), do: to_claude_code_tool_name(name)
  defp wire_name(name, false), do: name

  defp sanitize_tool_name(name) when is_binary(name),
    do: String.replace(name, ~r/[^a-zA-Z0-9_-]/, "_")

  defp sanitize_tool_name(_name), do: ""

  defp sanitize_id(id) when is_binary(id) do
    case sanitize_tool_name(Prompt.sanitize_surrogates(id)) do
      "" -> "tool"
      sanitized -> sanitized
    end
  end

  defp sanitize_id(_id), do: "tool"

  defp normalize_role(role) when role in [:user, "user"], do: :user
  defp normalize_role(role) when role in [:assistant, "assistant"], do: :assistant
  defp normalize_role(role) when role in [:tool, "tool"], do: :tool
  defp normalize_role(role), do: role

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_value, _key), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule Tackle.Plugins.MCP.Tool do
  @moduledoc false

  alias Tackle.Lib.JSON
  alias Tackle.Lib.Tool.Content
  alias Tackle.Plugins.MCP.Schema

  @name_limit 64
  @hash_length 12

  @spec create(String.t(), map(), GenServer.server(), module(), timeout()) ::
          {:ok, module()} | {:error, term()}
  def create(server_name, descriptor, client, connection, timeout) do
    with {:ok, raw_name} <- fetch_non_empty_string(descriptor, "name"),
         {:ok, description} <- fetch_description(descriptor, raw_name),
         {:ok, parameters_schema} <-
           Schema.to_tackle(Map.get(descriptor, "inputSchema", %{})) do
      public_name = public_name(server_name, raw_name)
      output_schema = Map.get(descriptor, "outputSchema")
      module = proxy_module(server_name, raw_name, {descriptor, connection, timeout})

      if Code.ensure_loaded?(module) and function_exported?(module, :mcp_descriptor, 0) and
           module.mcp_descriptor() == {descriptor, client, connection, timeout} do
        {:ok, module}
      else
        create_module(
          module,
          descriptor,
          client,
          connection,
          timeout,
          public_name,
          parameters_schema,
          output_schema,
          raw_name,
          description
        )
      end
    end
  end

  defp create_module(
         module,
         descriptor,
         client,
         connection,
         timeout,
         public_name,
         parameters_schema,
         output_schema,
         raw_name,
         description
       ) do
    quoted =
      quote do
        @behaviour Tackle.Lib.Tool

        def mcp_descriptor,
          do: unquote(Macro.escape({descriptor, client, connection, timeout}))

        @impl true
        def name, do: unquote(public_name)

        @impl true
        def description, do: unquote(description)

        @impl true
        def parameters_schema, do: unquote(Macro.escape(parameters_schema))

        @impl true
        def output_schema, do: unquote(Macro.escape(output_schema))

        @impl true
        def execute(arguments, _context) do
          unquote(__MODULE__).execute(
            unquote(Macro.escape(client)),
            unquote(raw_name),
            arguments,
            unquote(connection),
            unquote(timeout)
          )
        end
      end

    case Module.create(module, quoted, Macro.Env.location(__ENV__)) do
      {:module, ^module, _binary, _term} -> {:ok, module}
      other -> {:error, {:module_creation_failed, module, other}}
    end
  end

  @doc false
  @spec execute(GenServer.server(), String.t(), map(), module(), timeout()) ::
          {:ok, term()} | {:error, term()}
  def execute(client, raw_name, arguments, connection, timeout) do
    case connection.call_tool(client, raw_name, arguments, timeout: timeout) do
      {:ok, result} -> project_result(result)
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  @doc "Returns the stable, server-qualified name exposed to the model."
  @spec public_name(String.t(), String.t()) :: String.t()
  def public_name(server_name, raw_name)
      when is_binary(server_name) and is_binary(raw_name) do
    joined = "mcp__#{server_name}__#{raw_name}"
    normalized = Regex.replace(~r/[^A-Za-z0-9_-]/, joined, "_")

    if normalized == joined and byte_size(normalized) <= @name_limit do
      normalized
    else
      hash =
        :crypto.hash(:sha256, server_name <> <<0>> <> raw_name)
        |> Base.encode16(case: :lower)
        |> binary_part(0, @hash_length)

      prefix_length = @name_limit - @hash_length - 1
      prefix = truncate_utf8(normalized, prefix_length)
      prefix <> "_" <> hash
    end
  end

  defp truncate_utf8(value, max_bytes) do
    value
    |> String.codepoints()
    |> Enum.reduce_while("", fn codepoint, acc ->
      if byte_size(acc) + byte_size(codepoint) <= max_bytes,
        do: {:cont, acc <> codepoint},
        else: {:halt, acc}
    end)
  end

  defp proxy_module(server_name, raw_name, contract) do
    hash =
      :crypto.hash(:sha256, :erlang.term_to_binary({server_name, raw_name, contract}))
      |> Base.encode16(case: :upper)

    Module.concat(Tackle.Plugins.MCP.Generated, "Tool#{hash}")
  end

  defp fetch_non_empty_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:invalid_tool_field, key, value}}
    end
  end

  defp fetch_description(descriptor, raw_name) do
    case Map.get(descriptor, "description") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:ok, "MCP tool #{raw_name}"}
    end
  end

  defp project_result(%{"structuredContent" => structured}) when not is_nil(structured),
    do: {:ok, structured}

  defp project_result(%{"content" => content}) when is_list(content) do
    {text, images} = Enum.reduce(content, {[], []}, &project_block/2)
    text = text |> Enum.reverse() |> Enum.join("\n")
    images = Enum.reverse(images)

    if images == [] do
      {:ok, text}
    else
      {:ok, Content.new(text, images)}
    end
  end

  defp project_result(result), do: {:ok, result}

  defp project_block(%{"type" => "text", "text" => text}, {texts, images})
       when is_binary(text),
       do: {[text | texts], images}

  defp project_block(
         %{"type" => "image", "mimeType" => media_type, "data" => data},
         {texts, images}
       )
       when is_binary(media_type) and is_binary(data),
       do: {texts, [Content.image(media_type, data) | images]}

  defp project_block(%{"type" => "resource_link", "uri" => uri} = block, {texts, images})
       when is_binary(uri) do
    label = Map.get(block, "name", "resource")
    {["#{label}: #{uri}" | texts], images}
  end

  defp project_block(block, {texts, images}) do
    {["Unsupported MCP content: #{JSON.encode!(block)}" | texts], images}
  end

  defp format_error({:tool_error, result}) when is_map(result) do
    case Map.get(result, "content") do
      content when is_list(content) ->
        content
        |> Enum.flat_map(fn
          %{"type" => "text", "text" => text} when is_binary(text) -> [text]
          _block -> []
        end)
        |> case do
          [] -> "MCP tool call failed"
          messages -> "MCP tool call failed: #{Enum.join(messages, "\n")}"
        end

      _content ->
        "MCP tool call failed"
    end
  end

  defp format_error({:mcp_error, reason, message}) do
    detail = if is_binary(message) and message != "", do: message, else: inspect(reason)
    "MCP tool call failed: #{detail}"
  end

  defp format_error(reason), do: "MCP tool call failed: #{inspect(reason)}"
end

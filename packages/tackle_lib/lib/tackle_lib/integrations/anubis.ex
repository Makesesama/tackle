defmodule Tackle.Lib.Integrations.Anubis do
  @moduledoc """
  Integration helpers for exposing `Tackle.Lib.Tool` modules through Anubis MCP.

  This module deliberately does not own server setup, auth, or tenant scope. The
  host Anubis server should resolve/authorize the request, then pass a context
  builder to `dispatch/4`.

  ## Example

      def init(_client_info, frame) do
        {:ok, Tackle.Lib.Integrations.Anubis.register_all(frame, @tools)}
      end

      def handle_tool_call(name, params, frame) do
        Tackle.Lib.Integrations.Anubis.dispatch(name, params, frame,
          tools: @tools,
          context: &MyApp.MCP.Context.from_frame/1
        )
      end
  """

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Tackle.Lib.Integrations.Anubis.Schema, as: AnubisSchema
  alias Tackle.Lib.Integrations.Registry
  alias Tackle.Lib.Tool
  alias Tackle.Lib.Tool.{Call, Error, Result}

  @type dispatch_result :: {:reply, Response.t(), Frame.t()} | {:error, :unknown_tool}

  @doc "Registers all tools on an Anubis frame."
  @spec register_all(Frame.t(), [module()] | Registry.t(), keyword()) :: Frame.t()
  def register_all(%Frame{} = frame, tools_or_registry, opts \\ []) do
    tools_or_registry
    |> registry()
    |> Registry.entries()
    |> Enum.reduce(frame, fn entry, frame -> register_tool(frame, entry, opts) end)
  end

  @doc "Dispatches an Anubis tool call to a registered `Tackle.Lib.Tool` module."
  @spec dispatch(String.t(), map() | nil, Frame.t(), keyword()) :: dispatch_result()
  def dispatch(name, params, %Frame{} = frame, opts) when is_binary(name) do
    registry = opts |> Keyword.fetch!(:tools) |> registry()

    case Registry.lookup(registry, name) do
      nil ->
        {:error, :unknown_tool}

      %{module: tool_module, definition: definition} ->
        context = build_context(frame, opts)

        call = %Call{
          id: call_id(opts),
          name: name,
          arguments: Tool.normalize_args(tool_module, params || %{}),
          definition_id: definition.definition_id
        }

        {:reply, run_tool(tool_module, call, context), frame}
    end
  end

  defp register_tool(%Frame{} = frame, %{module: tool_module, definition: definition}, opts) do
    Frame.register_tool(frame, definition.name,
      description: tool_description(tool_module, definition, opts),
      input_schema: AnubisSchema.to_peri(tool_module.parameters_schema()),
      output_schema: tool_module |> Tool.output_schema() |> AnubisSchema.to_peri(),
      annotations: Keyword.get(opts, :annotations, %{}),
      title: Keyword.get(opts, :title),
      task_support: Keyword.get(opts, :task_support, :forbidden),
      scopes: Keyword.get(opts, :scopes, [])
    )
  end

  defp run_tool(tool_module, call, context) do
    case Tool.settle(tool_module, call, context) do
      {:ok, %Result{output: output}} when is_map(output) ->
        Response.structured(Response.tool(), output)

      {:ok, %Result{content: content}} ->
        Response.text(Response.tool(), content)

      {:error, %Error{message: message}} ->
        Response.error(Response.tool(), message)
    end
  end

  # Renders the description the MCP host should show. When the caller passes a
  # `:description_renderer` module, host-defined `description_metadata/0` is
  # rendered with it (e.g. XML for Anthropic-native MCP); otherwise the flat
  # `description/0` carried on the definition is used.
  defp tool_description(tool_module, definition, opts) do
    case Keyword.get(opts, :description_renderer) do
      nil -> definition.description
      renderer when is_atom(renderer) -> Tool.render_description(tool_module, renderer)
    end
  end

  defp registry(%Registry{} = registry), do: registry
  defp registry(tools) when is_list(tools), do: Registry.new(tools)

  defp build_context(frame, opts) do
    case Keyword.get(opts, :context, %{}) do
      fun when is_function(fun, 1) -> fun.(frame)
      context when is_map(context) -> context
      nil -> %{}
    end
  end

  defp call_id(opts), do: Keyword.get_lazy(opts, :call_id, &Tackle.Lib.ID.uuid4/0)
end

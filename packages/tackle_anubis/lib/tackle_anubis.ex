defmodule Tackle.Anubis do
  @moduledoc """
  Integration helpers for exposing `Tackle.Lib.Tool` modules through Anubis MCP.

  This module deliberately does not own server setup, auth, or tenant scope. The
  host Anubis server should resolve/authorize the request, then pass a context
  builder to `dispatch/4`.

  ## Example

      def init(_client_info, frame) do
        {:ok, Tackle.Anubis.register_all(frame, @tools)}
      end

      def handle_tool_call(name, params, frame) do
        Tackle.Anubis.dispatch(name, params, frame,
          tools: @tools,
          context: &MyApp.MCP.Context.from_frame/1
        )
      end
  """

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Tackle.Anubis.Schema, as: AnubisSchema
  alias Tackle.Lib.ID
  alias Tackle.Lib.Tool
  alias Tackle.Lib.Tool.{Call, Error, Registry, Result}

  @type dispatch_result :: {:reply, term(), term()} | {:error, :unknown_tool}

  @doc """
  Registers all tools on an Anubis frame, in their order.

  A list of tool modules is built into a `Tackle.Lib.Tool.Registry`, which
  raises `ArgumentError` for a module that is not a tool or a duplicate tool
  name.
  """
  @spec register_all(term(), [module()] | Registry.t(), keyword()) :: term()
  def register_all(%{__struct__: Frame} = frame, tools_or_registry, opts \\ []) do
    tools_or_registry
    |> registry()
    |> Registry.entries()
    |> Enum.reduce(frame, fn entry, frame -> register_tool(frame, entry, opts) end)
  end

  @doc "Dispatches an Anubis tool call to a registered `Tackle.Lib.Tool` module."
  @spec dispatch(String.t(), map() | nil, term(), keyword()) :: dispatch_result()
  def dispatch(name, params, %{__struct__: Frame} = frame, opts) when is_binary(name) do
    registry = opts |> Keyword.fetch!(:tools) |> registry()

    case Registry.lookup(registry, name) do
      nil ->
        {:error, :unknown_tool}

      %{module: tool_module} ->
        context = build_context(frame, opts)
        call = %Call{id: call_id(opts), name: name, arguments: params || %{}}

        {:reply, run_tool(tool_module, call, context), frame}
    end
  end

  defp register_tool(
         %{__struct__: Frame} = frame,
         %{module: tool_module, definition: definition},
         opts
       ) do
    registration_opts = [
      description: definition.description,
      input_schema: AnubisSchema.to_peri(tool_module.parameters_schema()),
      output_schema: tool_module |> Tool.output_schema() |> AnubisSchema.to_peri(),
      annotations: Keyword.get(opts, :annotations, %{}),
      title: Keyword.get(opts, :title),
      task_support: Keyword.get(opts, :task_support, :forbidden),
      scopes: Keyword.get(opts, :scopes, [])
    ]

    Frame.register_tool(frame, definition.name, registration_opts)
  end

  defp run_tool(tool_module, call, context) do
    response_type = Response.tool()

    case Tool.settle(tool_module, call, context) do
      {:ok, %Result{output: output}} when is_map(output) ->
        Response.structured(response_type, output)

      {:ok, %Result{content: content}} ->
        Response.text(response_type, content)

      # MCP clients pass tool results to a model, so they get the error's
      # model-facing content, not its host-facing message.
      {:error, %Error{content: content}} ->
        Response.error(response_type, content)
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

  defp call_id(opts), do: Keyword.get_lazy(opts, :call_id, &ID.uuid4/0)
end

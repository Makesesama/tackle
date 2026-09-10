defmodule Tackle.Lib.Tool do
  @moduledoc """
  Behaviour and dispatch glue for Tackle.Lib agent tools.

  A tool is any module the agent loop can describe to the LLM and execute. This
  is the single, clean tool contract Tackle.Lib's loop knows about — host
  applications implement it (or wrap their own richer tool abstractions behind
  it).

  ## The contract

    * `name/0` — the unique tool name the LLM uses to call it.
    * `description/0` — natural-language description for the system prompt.
    * `parameters_schema/0` — provider-neutral keyword schema describing input
      arguments.
    * `execute/2` — runs the tool with centrally validated/coerced args and a
      host-supplied context map, returning `{:ok, result}` or `{:error, reason}`.

  The schema itself is owned by `Tackle.Lib.Tool.Schema`, not by any provider
  adapter. Provider-specific projections should be derived at the adapter
  boundary (for example, `Tackle.Lib.Tool.Schema.JsonSchema.to_json_schema/1`).

  ## Adapting richer tool systems

  Tackle.Lib deliberately keeps this contract small. If your app has a more
  elaborate tool abstraction (e.g. surface-agnostic tools shared with an MCP
  server), implement `Tackle.Lib.Tool` as a thin façade over it — the loop only ever
  sees this behaviour.
  """

  require Logger

  alias Tackle.Lib.JSON
  alias Tackle.Lib.Tool.Schema

  @doc "Returns the unique name of the tool."
  @callback name() :: String.t()

  @doc "Returns a description of what the tool does (used in the system prompt)."
  @callback description() :: String.t()

  @doc """
  Returns the provider-neutral input schema for the tool.

  ## Example

      def parameters_schema do
        [
          query: [type: :string, required: true, description: "Search query"],
          limit: [type: :integer, description: "Max results to return"]
        ]
      end
  """
  @callback parameters_schema() :: Tackle.Lib.Tool.Schema.t()

  @doc "Optional provider-neutral output schema for hosts that want to validate results."
  @callback output_schema() :: Tackle.Lib.Tool.Schema.output_schema()

  @doc """
  Optional host-defined structured description metadata.

  When present, surfaces render this per their own convention (e.g. markdown for
  a prompt-driven loop, XML for Anthropic-native MCP) by passing it to a host
  renderer module via `render_description/2`. The metadata shape and the renderer
  are owned by the host; Tackle.Lib stays agnostic. `description/0` remains the flat
  fallback for consumers that only want a string.
  """
  @callback description_metadata() :: term() | nil

  @doc """
  Executes the tool with the given arguments and context.

    * `args` — map of argument values matching the parameters schema.
    * `context` — host-supplied context map (user info, permissions, etc.).

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @callback execute(args :: map(), context :: map()) :: {:ok, any()} | {:error, term()}

  @optional_callbacks output_schema: 0, description_metadata: 0

  @doc """
  Defines a Tackle.Lib tool with the canonical DSL.

  ## Example

      defmodule MyApp.Tools.Search do
        use Tackle.Lib.Tool

        tool_name "search"

        description "Search indexed documents."

        input do
          field :query, :string, required: true
          field :limit, :integer, default: 10
        end

        output do
          field :results, {:list, :map}, required: true
        end

        def run(%{"query" => query, "limit" => limit}, ctx) do
          MyApp.Search.run(query, limit, ctx)
        end
      end

  `use Tackle.Lib.Tool` generates the behaviour callbacks (`name/0`,
  `description/0`, `parameters_schema/0`, `output_schema/0`, and `execute/2`)
  from the DSL. Modules can still implement the callbacks manually when they are
  adapting an existing abstraction.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Tackle.Lib.Tool

      import Tackle.Lib.Tool.DSL,
        only: [tool_name: 1, description: 1, input: 1, output: 1, field: 2, field: 3]

      Module.register_attribute(__MODULE__, :tackle_tool_name, accumulate: false)
      Module.register_attribute(__MODULE__, :tackle_tool_description, accumulate: false)
      Module.register_attribute(__MODULE__, :tackle_schema_context, accumulate: false)
      Module.register_attribute(__MODULE__, :tackle_input_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :tackle_output_fields, accumulate: true)

      @before_compile Tackle.Lib.Tool
    end
  end

  @doc false
  def __field__(module, context, name, type, opts)
      when context in [:input, :output] and is_atom(name) and is_list(opts) do
    field = {name, Keyword.put(opts, :type, type)}

    attribute =
      case context do
        :input -> :tackle_input_fields
        :output -> :tackle_output_fields
      end

    Module.put_attribute(module, attribute, field)
  end

  def __field__(_module, nil, _name, _type, _opts) do
    raise ArgumentError, "field/3 must be called inside an input or output block"
  end

  def __field__(_module, _context, name, _type, opts) do
    raise ArgumentError,
          "field/3 expects an atom field name and keyword options, got: #{inspect(name)}, #{inspect(opts)}"
  end

  @doc false
  defmacro __before_compile__(env) do
    tool_name = Module.get_attribute(env.module, :tackle_tool_name)
    description = Module.get_attribute(env.module, :tackle_tool_description)
    input_schema = env.module |> Module.get_attribute(:tackle_input_fields) |> Enum.reverse()
    output_schema = env.module |> Module.get_attribute(:tackle_output_fields) |> Enum.reverse()

    validate_tool_attributes!(env, tool_name, description)

    output_schema = if output_schema == [], do: nil, else: output_schema
    defines_output_schema? = Module.defines?(env.module, {:output_schema, 0})

    quote do
      @impl Tackle.Lib.Tool
      def name, do: unquote(tool_name)

      @impl Tackle.Lib.Tool
      def description, do: unquote(description)

      @impl Tackle.Lib.Tool
      def parameters_schema, do: unquote(Macro.escape(input_schema))

      unless unquote(defines_output_schema?) do
        @impl Tackle.Lib.Tool
        def output_schema, do: unquote(Macro.escape(output_schema))
      end

      @impl Tackle.Lib.Tool
      def execute(args, context), do: run(args, context)
    end
  end

  defp validate_tool_attributes!(env, tool_name, description) do
    unless is_binary(tool_name) and tool_name != "" do
      raise ArgumentError, "#{inspect(env.module)} must define tool_name \"...\""
    end

    unless is_binary(description) and description != "" do
      raise ArgumentError, "#{inspect(env.module)} must define description \"...\""
    end

    unless Module.defines?(env.module, {:run, 2}) do
      raise ArgumentError, "#{inspect(env.module)} must define run/2"
    end
  end

  @doc """
  The tool's public name.
  """
  @spec tool_name(module()) :: String.t()
  def tool_name(tool_module), do: tool_module.name()

  @doc """
  Returns Tackle.Lib's provider-neutral definition for a tool module.
  """
  @spec definition(module()) :: %{
          name: String.t(),
          description: String.t(),
          input_schema: [map()],
          output_schema: Tackle.Lib.Tool.Schema.output_schema(),
          definition_id: String.t()
        }
  def definition(tool_module) do
    definition =
      Schema.definition(
        tool_module.name(),
        tool_module.description(),
        tool_module.parameters_schema(),
        output_schema: output_schema(tool_module)
      )

    Map.put(definition, :definition_id, definition_id(definition))
  end

  @doc "Returns a deterministic id for a provider-neutral tool definition."
  @spec definition_id(map()) :: String.t()
  def definition_id(definition) do
    definition
    |> Map.drop([:definition_id])
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc """
  Returns the optional output schema for a tool module.
  """
  @spec output_schema(module()) :: Tackle.Lib.Tool.Schema.output_schema()
  def output_schema(tool_module) do
    if function_exported?(tool_module, :output_schema, 0),
      do: tool_module.output_schema(),
      else: nil
  end

  @doc """
  Returns the optional structured description metadata for a tool module, or nil.

  The metadata shape is host-defined — Tackle.Lib only knows it may exist and that a
  host renderer can turn it into text (see `render_description/2`).
  """
  @spec description_metadata(module()) :: term() | nil
  def description_metadata(tool_module) do
    if function_exported?(tool_module, :description_metadata, 0),
      do: tool_module.description_metadata(),
      else: nil
  end

  @doc """
  Renders a tool module's description for a given surface renderer.

  Prefers host-defined structured `description_metadata/0`, rendered by calling
  `renderer.render/1` on it, and falls back to the flat `description/0` string
  when no metadata is declared. The renderer module and metadata shape are owned
  by the host; Tackle.Lib only wires the selection.
  """
  @spec render_description(module(), module()) :: String.t()
  def render_description(tool_module, renderer) when is_atom(renderer) do
    case description_metadata(tool_module) do
      nil -> tool_module.description()
      metadata -> renderer.render(metadata)
    end
  end

  @doc """
  Builds a tool description block for the system prompt.

  Pass `renderer` to render host-defined `description_metadata/0` (via
  `render_description/2`) instead of the flat `description/0`.
  """
  @spec build_tool_description(module(), module() | nil) :: String.t()
  def build_tool_description(tool_module, renderer \\ nil) do
    name = tool_module.name()
    description = render_description_with(tool_module, renderer)
    params = tool_module.parameters_schema()
    definition_id = definition(tool_module).definition_id

    """
    ### #{name}
    Definition ID: #{definition_id}

    #{description}

    Parameters:
    #{format_params(params)}
    """
  end

  defp render_description_with(tool_module, nil), do: tool_module.description()

  defp render_description_with(tool_module, renderer),
    do: render_description(tool_module, renderer)

  defp format_params(params) do
    Enum.map_join(params, "\n", fn {param_name, opts} ->
      type = Keyword.get(opts, :type, :string)
      required = if Keyword.get(opts, :required, false), do: " (required)", else: ""
      desc = Keyword.get(opts, :description, "")
      "    - #{param_name}: #{format_type(type)}#{required} - #{desc}"
    end)
  end

  @doc """
  Finds a tool module by name from a list of tools.
  """
  @spec find_tool([module()], String.t()) :: module() | nil
  def find_tool(tools, name) do
    Enum.find(tools, fn tool -> tool.name() == name end)
  end

  @doc """
  Normalizes wire-format arguments before schema validation.

  Some tool providers serialize nested object arguments as JSON strings. Keep
  the schema validator provider-neutral, but decode those map-typed fields at
  the Tackle.Lib JSON boundary using the configured `Tackle.Lib.JSON` adapter.
  """
  @spec normalize_args(module(), map() | nil) :: map()
  def normalize_args(tool_module, args) do
    normalize_map_arguments(tool_module.parameters_schema(), args || %{})
  end

  @doc """
  Validates and coerces arguments for a tool module.
  """
  @spec validate_args(module(), map() | nil) :: {:ok, map()} | {:error, String.t()}
  def validate_args(tool_module, args) do
    schema = tool_module.parameters_schema()

    case Schema.validate(schema, normalize_map_arguments(schema, args || %{})) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, errors} -> {:error, Schema.format_errors(errors)}
    end
  end

  @doc """
  Executes and settles a tool call.

  Settlement centralizes the full local tool pipeline:

    * decode/validate input
    * execute host tool
    * validate output when an output schema exists
    * encode/project output for the model transcript
  """
  @spec settle(module(), Tackle.Lib.Tool.Call.t(), map()) ::
          {:ok, Tackle.Lib.Tool.Result.t()} | {:error, Tackle.Lib.Tool.Error.t()}
  def settle(tool_module, %Tackle.Lib.Tool.Call{} = call, context) do
    with {:ok, normalized_args} <- validate_args(tool_module, call.arguments),
         {:ok, raw_result} <- execute_tool(tool_module, normalized_args, context),
         {:ok, output} <- validate_output(tool_module, raw_result) do
      {:ok,
       %Tackle.Lib.Tool.Result{
         tool_call_id: call.id,
         name: call.name,
         raw: raw_result,
         output: output,
         content: project_output(output),
         metadata: %{definition_id: call.definition_id}
       }}
    else
      {:error, {:invalid_output, reason}} ->
        {:error, tool_error(call, :invalid_output, reason)}

      {:error, {:tool_execution_error, reason}} when is_binary(reason) ->
        {:error, tool_error(call, :execution_error, reason, reason)}

      {:error, {:tool_execution_error, reason}} ->
        {:error,
         tool_error(call, :execution_error, "Tool execution failed: #{inspect(reason)}", reason)}

      {:error, reason} when is_binary(reason) ->
        {:error, tool_error(call, :invalid_input, reason)}

      {:error, reason} ->
        {:error,
         tool_error(call, :execution_error, "Tool execution failed: #{inspect(reason)}", reason)}
    end
  end

  @doc """
  Executes a tool call and returns a formatted string result.

  Kept as a compatibility wrapper for callers that have not adopted
  `settle/3` yet.
  """
  @spec execute_tool_call(module(), map() | nil, map()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute_tool_call(tool_module, args, context) do
    call = %Tackle.Lib.Tool.Call{id: "legacy", name: tool_module.name(), arguments: args || %{}}

    case settle(tool_module, call, context) do
      {:ok, %Tackle.Lib.Tool.Result{content: content}} ->
        {:ok, content}

      {:error, %Tackle.Lib.Tool.Error{reason: :execution_error, message: message}} ->
        {:error, message}

      {:error, %Tackle.Lib.Tool.Error{content: content}} ->
        {:error, content}
    end
  end

  defp execute_tool(tool_module, args, context) do
    case tool_module.execute(args, context) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:tool_execution_error, reason}}
    end
  rescue
    error ->
      stacktrace = __STACKTRACE__

      Logger.error(fn ->
        [
          "Tool ",
          inspect(tool_module),
          " raised: ",
          Exception.format(:error, error, stacktrace)
        ]
      end)

      {:error, {:exception, error}}
  end

  defp validate_output(tool_module, result) do
    case output_schema(tool_module) do
      nil ->
        {:ok, result}

      schema ->
        case Schema.validate_output(schema, result) do
          {:ok, output} -> {:ok, output}
          {:error, reason} -> {:error, {:invalid_output, reason}}
        end
    end
  end

  defp project_output(result), do: format_result(result)

  defp tool_error(call, reason, message, details \\ nil) do
    %Tackle.Lib.Tool.Error{
      tool_call_id: call.id,
      name: call.name,
      reason: reason,
      message: message,
      content: sanitized_tool_error_content(reason),
      details: details,
      metadata: %{definition_id: call.definition_id}
    }
  end

  defp sanitized_tool_error_content(:invalid_input) do
    "Error: The tool received invalid input and could not run."
  end

  defp sanitized_tool_error_content(_reason) do
    "Error: The tool failed while completing the request."
  end

  defp format_type(:string), do: "string"
  defp format_type(:integer), do: "integer"
  defp format_type(:float), do: "number"
  defp format_type(:boolean), do: "boolean"
  defp format_type({:list, inner}), do: "array of #{format_type(inner)}"
  defp format_type(:map), do: "object"
  defp format_type(other), do: inspect(other)

  defp normalize_map_arguments(schema, args) when is_list(schema) and is_map(args) do
    Enum.reduce(schema, args, fn {field, opts}, acc ->
      normalize_map_argument(acc, to_string(field), Keyword.get(opts, :type))
    end)
  end

  defp normalize_map_arguments(_schema, args) when is_map(args), do: args
  defp normalize_map_arguments(_schema, _args), do: %{}

  defp normalize_map_argument(args, field, :map) do
    case fetch_argument(args, field) do
      {:ok, key, value} when is_binary(value) ->
        case JSON.decode(value) do
          {:ok, decoded} when is_map(decoded) -> Map.put(args, key, decoded)
          _ -> args
        end

      _ ->
        args
    end
  end

  defp normalize_map_argument(args, _field, _type), do: args

  defp fetch_argument(args, field) do
    atom_field = safe_existing_atom(field)

    cond do
      Map.has_key?(args, field) -> {:ok, field, Map.get(args, field)}
      atom_field && Map.has_key?(args, atom_field) -> {:ok, atom_field, Map.get(args, atom_field)}
      true -> :error
    end
  end

  defp safe_existing_atom(field) do
    String.to_existing_atom(field)
  rescue
    ArgumentError -> nil
  end

  defp format_result(result) when is_map(result) or is_list(result) do
    JSON.encode!(result)
  end

  defp format_result(result) when is_binary(result), do: result
  defp format_result(result), do: inspect(result)
end

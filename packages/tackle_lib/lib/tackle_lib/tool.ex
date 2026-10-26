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

  ## Errors the model sees

  A tool reports an expected failure by returning `{:error, reason}`.
  `settle/3` turns it into a `Tackle.Lib.Tool.Error` whose `content` is what
  the model sees in its transcript:

    * a binary `reason` is the model-facing message: the content is
      `"Error: " <> reason`, so the model can react to failures such as a
      missing file or a non-zero exit status. Write these messages for the
      model, and never put secrets (credentials, tokens, private data) in
      them;
    * any other `reason` gets a generic content, `"Error: The tool failed
      while completing the request."`; the reason stays in the error's
      host-facing `message` and `details`.

  Arguments that fail schema validation, and provider arguments that are not
  a JSON object (see `Tackle.Lib.Tool.Call`), settle as `:invalid_input`
  errors that show the model what was wrong, such as `"Error: Invalid tool
  arguments: path: is required"`; these name only schema fields and their
  constraints. Exceptions, exits, and throws from a tool, and results that do
  not match the output schema, are bugs: the model sees the generic content.

  Model-facing text is made valid UTF-8 before it enters the transcript:
  invalid bytes in a binary result, a `Tackle.Lib.Tool.Content` text, or an
  error message are replaced with U+FFFD.

  ## Adapting richer tool systems

  Tackle.Lib deliberately keeps this contract small. If your app has a more
  elaborate tool abstraction (e.g. surface-agnostic tools shared with an MCP
  server), implement `Tackle.Lib.Tool` as a thin façade over it — the loop only ever
  sees this behaviour.
  """

  require Logger

  alias Tackle.Lib.JSON
  alias Tackle.Lib.Tool.Content
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

  Returns `{:ok, result}` or `{:error, reason}`. A binary `reason` is shown to
  the model; any other reason is not (see "Errors the model sees" in the
  module docs).
  """
  @callback execute(args :: map(), context :: map()) :: {:ok, any()} | {:error, term()}

  @doc """
  Optional declaration of the tool's effects outside the agent.

  `:read_only` declares that the tool only observes (for example, reading a
  file) and that running it again cannot change anything. The loop does not run
  the host's `:before_tool_execution` gate for a step whose calls are all
  read-only. Tools without this callback are `:external`.
  """
  @callback effect() :: :read_only | :external

  @optional_callbacks output_schema: 0, description_metadata: 0, effect: 0

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
  from the DSL, and raises `ArgumentError` at compile time when the input or
  output fields do not pass `Tackle.Lib.Tool.Schema.validate_schema/1`.
  Modules can still implement the callbacks manually when they are adapting
  an existing abstraction; `Tackle.Lib.Tool.Registry.new/1` checks their
  schemas when they are registered.
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
    validate_schema!(env, "input", input_schema)
    validate_schema!(env, "output", output_schema)

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

  defp validate_schema!(env, kind, schema) do
    case Schema.validate_schema(schema) do
      :ok ->
        :ok

      {:error, message} ->
        raise ArgumentError, "#{inspect(env.module)} has an invalid #{kind} schema: #{message}"
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

  @doc "Returns a tool module's declared effect; `:external` unless it declares `:read_only`."
  @spec effect(module()) :: :read_only | :external
  def effect(tool_module) do
    if function_exported?(tool_module, :effect, 0) and tool_module.effect() == :read_only,
      do: :read_only,
      else: :external
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
  Validates and coerces arguments for a tool module with
  `Tackle.Lib.Tool.Schema.validate/2`.

  Returns the normalized arguments, or the validation errors formatted with
  `Tackle.Lib.Tool.Schema.format_errors/1`.
  """
  @spec validate_args(module(), term()) :: {:ok, map()} | {:error, String.t()}
  def validate_args(tool_module, args) do
    case Schema.validate(tool_module.parameters_schema(), args) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, errors} -> {:error, Schema.format_errors(errors)}
    end
  end

  @doc """
  Executes and settles a tool call.

  Settlement centralizes the full local tool pipeline:

    * reject a call whose provider arguments were not a JSON object
      (`Tackle.Lib.Tool.Call`'s `argument_error`) without running the tool
    * validate and coerce the arguments
    * execute host tool
    * validate output when an output schema exists
    * encode/project output for the model transcript

  A tool that returns `%Tackle.Lib.Tool.Content{}` settles into a text
  projection plus its extra content parts; every other result settles into text
  only. Failures settle into a `Tackle.Lib.Tool.Error` whose `content` follows
  the rules in "Errors the model sees" in the module docs.
  """
  @spec settle(module(), Tackle.Lib.Tool.Call.t(), map()) ::
          {:ok, Tackle.Lib.Tool.Result.t()} | {:error, Tackle.Lib.Tool.Error.t()}
  def settle(tool_module, %Tackle.Lib.Tool.Call{} = call, context) do
    with {:ok, normalized_args} <- validate_input(tool_module, call),
         {:ok, raw_result} <- execute_tool(tool_module, normalized_args, context),
         {:ok, output} <- validate_output(tool_module, raw_result),
         {:ok, {content, parts}} <- project_output(output) do
      {:ok,
       %Tackle.Lib.Tool.Result{
         tool_call_id: call.id,
         name: call.name,
         raw: raw_result,
         output: output,
         content: content,
         parts: parts,
         metadata: %{definition_id: call.definition_id}
       }}
    else
      {:error, {:invalid_input, message}} ->
        {:error, tool_error(call, :invalid_input, message, nil, message)}

      {:error, {:invalid_output, reason}} when is_binary(reason) ->
        {:error, tool_error(call, :invalid_output, reason)}

      # A host output validator may return any term.
      {:error, {:invalid_output, reason}} ->
        {:error,
         tool_error(call, :invalid_output, "Invalid tool output: #{inspect(reason)}", reason)}

      {:error, {:tool_execution_error, reason}} when is_binary(reason) and reason != "" ->
        {:error, tool_error(call, :execution_error, reason, reason, reason)}

      {:error, {:tool_execution_error, reason}} ->
        {:error,
         tool_error(call, :execution_error, "Tool execution failed: #{inspect(reason)}", reason)}

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

  defp validate_input(_tool_module, %Tackle.Lib.Tool.Call{argument_error: :invalid_json}),
    do: {:error, {:invalid_input, "Invalid tool arguments: arguments are not valid JSON"}}

  defp validate_input(_tool_module, %Tackle.Lib.Tool.Call{argument_error: :not_an_object}),
    do: {:error, {:invalid_input, "Invalid tool arguments: arguments must be a JSON object"}}

  defp validate_input(tool_module, %Tackle.Lib.Tool.Call{arguments: arguments}) do
    case validate_args(tool_module, arguments) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, message} -> {:error, {:invalid_input, message}}
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
  catch
    # An exit (such as a GenServer.call timeout) or a throw from a tool is a
    # failed execution like a raise, not a crash of the caller.
    kind, reason ->
      stacktrace = __STACKTRACE__

      Logger.error(fn ->
        ["Tool ", inspect(tool_module), " failed: ", Exception.format(kind, reason, stacktrace)]
      end)

      {:error, {kind, reason}}
  end

  defp validate_output(_tool_module, %Tackle.Lib.Tool.Content{} = content), do: {:ok, content}

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

  defp project_output(%Tackle.Lib.Tool.Content{text: text}) when not is_binary(text),
    do: {:error, {:invalid_output, "Tool content text must be a string, got: #{inspect(text)}"}}

  defp project_output(%Tackle.Lib.Tool.Content{text: text, parts: parts}) do
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

  # `model_message` is what the model may see; without one the model sees a
  # generic content for the error's reason.
  defp tool_error(call, reason, message, details \\ nil, model_message \\ nil) do
    %Tackle.Lib.Tool.Error{
      tool_call_id: call.id,
      name: call.name,
      reason: reason,
      message: model_text(message),
      content: error_content(model_message),
      details: details,
      metadata: %{definition_id: call.definition_id}
    }
  end

  defp error_content(nil), do: "Error: The tool failed while completing the request."
  defp error_content(message), do: "Error: " <> model_text(message)

  # Transcript text is sent to providers as JSON on every later request, so
  # it must be valid UTF-8.
  defp model_text(text), do: String.replace_invalid(text)

  defp sanitize_part(%{"type" => "text", "text" => text} = part),
    do: %{part | "text" => model_text(text)}

  defp sanitize_part(part), do: part

  defp format_type(:string), do: "string"
  defp format_type(:integer), do: "integer"
  defp format_type(:float), do: "number"
  defp format_type(:boolean), do: "boolean"
  defp format_type({:list, inner}), do: "array of #{format_type(inner)}"
  defp format_type(:map), do: "object"

  defp format_result(result) when is_map(result) or is_list(result) do
    JSON.encode!(result)
  end

  defp format_result(result) when is_binary(result), do: result
  defp format_result(result), do: inspect(result)
end

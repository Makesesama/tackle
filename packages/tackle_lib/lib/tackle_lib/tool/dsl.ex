defmodule Tackle.Lib.Tool.DSL do
  @moduledoc """
  The macros `use Tackle.Lib.Tool` imports to declare a tool.

  See `Tackle.Lib.Tool.__using__/1` for an example. `use Tackle.Lib.Tool`
  generates the behaviour callbacks from these declarations when the module
  compiles, and raises `ArgumentError` when the tool has no name, description,
  or `run/2`, or when its input or output fields do not pass
  `Tackle.Lib.Tool.Schema.validate_schema/1`.
  """

  alias Tackle.Lib.Tool.Schema

  @doc false
  @spec __using_ast__() :: Macro.t()
  def __using_ast__ do
    quote do
      @behaviour Tackle.Lib.Tool

      import Tackle.Lib.Tool.DSL,
        only: [tool_name: 1, description: 1, input: 1, output: 1, field: 2, field: 3]

      Module.register_attribute(__MODULE__, :tackle_tool_name, accumulate: false)
      Module.register_attribute(__MODULE__, :tackle_tool_description, accumulate: false)
      Module.register_attribute(__MODULE__, :tackle_schema_context, accumulate: false)
      Module.register_attribute(__MODULE__, :tackle_input_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :tackle_output_fields, accumulate: true)

      @before_compile Tackle.Lib.Tool.DSL
    end
  end

  @doc "Defines the public name the LLM uses to call this tool."
  defmacro tool_name(name) do
    quote do
      @tackle_tool_name unquote(name)
    end
  end

  @doc "Defines the natural-language description used in prompts and integrations."
  defmacro description(description) do
    quote do
      @tackle_tool_description String.trim(unquote(description))
    end
  end

  @doc "Defines the input schema for this tool."
  defmacro input(do: block) do
    quote do
      @tackle_schema_context :input
      unquote(block)
      @tackle_schema_context nil
    end
  end

  @doc "Defines the optional output schema for this tool."
  defmacro output(do: block) do
    quote do
      @tackle_schema_context :output
      unquote(block)
      @tackle_schema_context nil
    end
  end

  @doc "Adds a field to the surrounding `input` or `output` block."
  defmacro field(name, type, opts \\ []) do
    quote bind_quoted: [name: name, type: type, opts: opts] do
      Tackle.Lib.Tool.DSL.__field__(__MODULE__, @tackle_schema_context, name, type, opts)
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
end

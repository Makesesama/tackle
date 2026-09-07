defmodule Tackle.Tool.DSL do
  @moduledoc false

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
      Tackle.Tool.__field__(__MODULE__, @tackle_schema_context, name, type, opts)
    end
  end
end

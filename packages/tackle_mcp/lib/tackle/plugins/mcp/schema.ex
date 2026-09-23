defmodule Tackle.Plugins.MCP.Schema do
  @moduledoc """
  Conservative projection from an MCP tool's JSON Schema into `Tackle.Lib.Tool.Schema`.

  Tackle's native schema is intentionally smaller than JSON Schema. This module
  preserves top-level properties, required fields, descriptions, defaults, and
  enums when their types have an exact Tackle representation. Nested object
  constraints remain the MCP server's responsibility. A common object-or-string
  union is projected as an object (the JSON string alternative is not exposed
  to the model); other unsupported property schemas are rejected during discovery.
  """

  @type result :: {:ok, Tackle.Lib.Tool.Schema.t()} | {:error, term()}

  @doc "Projects an MCP input schema into Tackle's provider-neutral tool schema."
  @spec to_tackle(term()) :: result()
  def to_tackle(%{} = schema) do
    with :ok <- validate_root_type(schema),
         {:ok, properties} <- fetch_properties(schema),
         {:ok, required} <- fetch_required(schema),
         {:ok, fields} <- project_properties(properties, required) do
      {:ok, Enum.reverse(fields)}
    end
  end

  def to_tackle(schema), do: {:error, {:invalid_input_schema, schema}}

  defp project_properties(properties, required) do
    properties
    |> Enum.sort_by(fn {name, _schema} -> name end)
    |> Enum.reduce_while({:ok, []}, &project_property(&1, &2, required))
  end

  defp project_property({name, %{} = property}, {:ok, fields}, required)
       when is_binary(name) do
    with :ok <- validate_field_name(name),
         {:ok, type} <- property_type(property) do
      opts = field_options(property, type, MapSet.member?(required, name))

      # Tackle's native schema is a keyword list. Connections are trusted
      # startup configuration and each discovered field therefore becomes
      # one bounded VM atom, just like each generated proxy module.
      {:cont, {:ok, [{String.to_atom(name), opts} | fields]}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp project_property({name, property}, _acc, _required) do
    {:halt, {:error, {:invalid_property_schema, name, property}}}
  end

  defp field_options(property, type, required?) do
    [
      type: type,
      required: required?,
      description: property["description"],
      default: property["default"],
      enum: property["enum"]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp validate_root_type(%{"type" => type}) when type not in ["object", nil],
    do: {:error, {:unsupported_root_type, type}}

  defp validate_root_type(_schema), do: :ok

  defp fetch_properties(schema) do
    case Map.get(schema, "properties", %{}) do
      properties when is_map(properties) -> {:ok, properties}
      properties -> {:error, {:invalid_properties, properties}}
    end
  end

  defp fetch_required(schema) do
    case Map.get(schema, "required", []) do
      required when is_list(required) -> validate_required(required)
      required -> {:error, {:invalid_required, required}}
    end
  end

  defp validate_required(required) do
    if Enum.all?(required, &is_binary/1) do
      {:ok, MapSet.new(required)}
    else
      {:error, {:invalid_required, required}}
    end
  end

  defp validate_field_name(name) do
    if name != "" and byte_size(name) <= 128,
      do: :ok,
      else: {:error, {:invalid_property_name, name}}
  end

  defp property_type(%{"oneOf" => variants} = property) when is_list(variants) do
    # Tackle's native schema cannot represent unions. For object-or-JSON-string
    # inputs, advertise the structured object branch; the MCP server validates
    # the full schema after execution. Do not reject the entire tool catalog.
    case variants do
      [%{"type" => "object"}, %{"type" => "string"}] -> {:ok, :map}
      [%{"type" => "string"}, %{"type" => "object"}] -> {:ok, :map}
      _ -> {:error, {:unsupported_property_schema, property}}
    end
  end

  defp property_type(%{"type" => "string"}), do: {:ok, :string}
  defp property_type(%{"type" => "integer"}), do: {:ok, :integer}
  defp property_type(%{"type" => "number"}), do: {:ok, :float}
  defp property_type(%{"type" => "boolean"}), do: {:ok, :boolean}
  defp property_type(%{"type" => "object"}), do: {:ok, :map}

  defp property_type(%{"type" => "array", "items" => %{} = items}) do
    with {:ok, type} <- property_type(items), do: {:ok, {:list, type}}
  end

  defp property_type(%{"type" => "array"}), do: {:ok, {:list, :map}}
  defp property_type(property), do: {:error, {:unsupported_property_schema, property}}
end

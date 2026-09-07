defmodule Tackle.Tool.Schema.JsonSchema do
  @moduledoc """
  JSON Schema projection and validation for Tackle's native tool schema.

  This module is intentionally separate from `Tackle.Tool.Schema` so core Tackle
  remains format-agnostic. Provider adapters that speak JSON Schema can opt into
  this projection at the adapter boundary.
  """

  @type schema :: Tackle.Tool.Schema.t()

  @doc "Projects Tackle's keyword schema into JSON Schema object form."
  @spec to_json_schema(schema()) :: map()
  def to_json_schema(schema) do
    properties =
      Map.new(schema, fn {field, opts} ->
        {to_string(field), field_json_schema(opts)}
      end)

    required =
      schema
      |> Enum.filter(fn {_field, opts} -> Keyword.get(opts, :required, false) end)
      |> Enum.map(fn {field, _opts} -> to_string(field) end)

    %{"type" => "object", "properties" => properties, "required" => required}
  end

  @doc "Validates output against the JSON Schema subset emitted by `to_json_schema/1`."
  @spec validate_output(map(), term()) :: {:ok, term()} | {:error, String.t()}
  def validate_output(%{} = schema, output) do
    case validate_json_schema(schema, output, "$") do
      :ok -> {:ok, output}
      {:error, message} -> {:error, "Invalid tool output: #{message}"}
    end
  end

  @doc "Alias for validator tuples accepted by `Tackle.Tool.Schema.validate_output/2`."
  @spec validate(map(), term()) :: {:ok, term()} | {:error, String.t()}
  def validate(schema, output), do: validate_output(schema, output)

  defp validate_json_schema(%{"type" => types} = schema, value, path) when is_list(types) do
    if is_nil(value) and "null" in types do
      :ok
    else
      schema
      |> Map.put("type", Enum.reject(types, &(&1 == "null")))
      |> validate_json_schema(value, path)
    end
  end

  defp validate_json_schema(%{type: type} = schema, value, path) do
    schema
    |> Map.new(fn {key, val} -> {to_string(key), val} end)
    |> Map.put("type", to_string(type))
    |> validate_json_schema(value, path)
  end

  defp validate_json_schema(%{"type" => [type]} = schema, value, path) do
    schema
    |> Map.put("type", type)
    |> validate_json_schema(value, path)
  end

  defp validate_json_schema(%{"type" => "object"} = schema, value, path) when is_map(value) do
    required = Map.get(schema, "required", [])
    properties = Map.get(schema, "properties", %{})

    with :ok <- validate_required(value, required, path) do
      validate_properties(value, properties, path)
    end
  end

  defp validate_json_schema(%{"type" => "object"}, _value, path),
    do: {:error, "#{path} must be an object"}

  defp validate_json_schema(%{"type" => "array", "items" => item_schema}, value, path)
       when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      case validate_json_schema(item_schema, item, "#{path}[#{index}]") do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_json_schema(%{"type" => "array"}, _value, path),
    do: {:error, "#{path} must be an array"}

  defp validate_json_schema(%{"enum" => values}, value, path) when is_list(values) do
    if value in values,
      do: :ok,
      else: {:error, "#{path} must be one of #{Enum.join(values, ", ")}"}
  end

  defp validate_json_schema(%{"type" => "string"}, value, path) do
    if is_binary(value), do: :ok, else: {:error, "#{path} must be a string"}
  end

  defp validate_json_schema(%{"type" => "integer"}, value, path) do
    if is_integer(value), do: :ok, else: {:error, "#{path} must be an integer"}
  end

  defp validate_json_schema(%{"type" => "number"}, value, path) do
    if is_integer(value) or is_float(value), do: :ok, else: {:error, "#{path} must be a number"}
  end

  defp validate_json_schema(%{"type" => "boolean"}, value, path) do
    if is_boolean(value), do: :ok, else: {:error, "#{path} must be a boolean"}
  end

  defp validate_json_schema(_schema, _value, _path), do: :ok

  defp validate_required(value, required, path) do
    Enum.reduce_while(required, :ok, fn field, :ok ->
      if has_string_or_atom_key?(value, field) do
        {:cont, :ok}
      else
        {:halt, {:error, "#{path}.#{field} is required"}}
      end
    end)
  end

  defp validate_properties(value, properties, path) do
    Enum.reduce_while(properties, :ok, fn {field, schema}, :ok ->
      case fetch_string_or_atom_key(value, field) do
        {:ok, nil} -> {:cont, :ok}
        {:ok, field_value} -> validate_property(field_value, schema, "#{path}.#{field}")
        :error -> {:cont, :ok}
      end
    end)
  end

  defp validate_property(value, schema, path) do
    case validate_json_schema(schema, value, path) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp has_string_or_atom_key?(map, field) do
    Map.has_key?(map, field) ||
      case safe_existing_atom(field) do
        nil -> false
        atom -> Map.has_key?(map, atom)
      end
  end

  defp fetch_string_or_atom_key(map, field) do
    atom_field = safe_existing_atom(field)

    cond do
      Map.has_key?(map, field) -> {:ok, Map.get(map, field)}
      atom_field && Map.has_key?(map, atom_field) -> {:ok, Map.get(map, atom_field)}
      true -> :error
    end
  end

  defp safe_existing_atom(field) do
    String.to_existing_atom(field)
  rescue
    ArgumentError -> nil
  end

  defp field_json_schema(opts) do
    type = Keyword.get(opts, :type, :string)

    %{}
    |> Map.merge(type_json_schema(type))
    |> maybe_put("description", Keyword.get(opts, :description))
    |> maybe_put("default", Keyword.get(opts, :default))
    |> maybe_put("enum", Keyword.get(opts, :enum))
  end

  defp type_json_schema(:string), do: %{"type" => "string"}
  defp type_json_schema(:integer), do: %{"type" => "integer"}
  defp type_json_schema(:float), do: %{"type" => "number"}
  defp type_json_schema(:boolean), do: %{"type" => "boolean"}
  defp type_json_schema(:map), do: %{"type" => "object"}

  defp type_json_schema({:list, inner}),
    do: %{"type" => "array", "items" => type_json_schema(inner)}

  defp type_json_schema({:array, inner}),
    do: %{"type" => "array", "items" => type_json_schema(inner)}

  defp type_json_schema(_type), do: %{"type" => "string"}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

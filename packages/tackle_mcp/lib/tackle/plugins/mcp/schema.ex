defmodule Tackle.Plugins.MCP.Schema do
  @moduledoc """
  Conservative projection from an MCP tool's JSON Schema into `Tackle.Lib.Tool.Schema`.

  Tackle's native schema is intentionally smaller than JSON Schema. This module
  preserves top-level properties, required fields, descriptions, defaults, and
  enums when their types have an exact Tackle representation. Nullable top-level
  fields expressed as `anyOf`, `oneOf`, or a type array retain explicit nulls.
  Nested object constraints remain the MCP server's responsibility. A common
  object-or-string union is projected as an object (the JSON string alternative
  is not exposed to the model); other unsupported property schemas, and
  options Tackle cannot represent (such as an `enum` that is not a list), are
  rejected during discovery.
  """

  @type result :: {:ok, Tackle.Lib.Tool.Schema.t()} | {:error, term()}

  @doc "Projects an MCP input schema into Tackle's provider-neutral tool schema."
  @spec to_tackle(term()) :: result()
  def to_tackle(%{} = schema) do
    with :ok <- validate_root_type(schema),
         {:ok, properties} <- fetch_properties(schema),
         {:ok, required} <- fetch_required(schema),
         {:ok, fields} <- project_properties(properties, required),
         fields = Enum.reverse(fields),
         :ok <- validate_projection(fields) do
      {:ok, fields}
    end
  end

  def to_tackle(schema), do: {:error, {:invalid_input_schema, schema}}

  # Option values come from the server (a non-string description, an enum
  # that is not a list); a schema Tackle cannot register is rejected here.
  defp validate_projection(fields) do
    case Tackle.Lib.Tool.Schema.validate_schema(fields) do
      :ok -> :ok
      {:error, message} -> {:error, {:invalid_input_schema, message}}
    end
  end

  defp project_properties(properties, required) do
    properties
    |> Enum.sort_by(fn {name, _schema} -> name end)
    |> Enum.reduce_while({:ok, []}, &project_property(&1, &2, required))
  end

  defp project_property({name, %{} = property}, {:ok, fields}, required)
       when is_binary(name) do
    with :ok <- validate_field_name(name),
         {:ok, projected_property, nullable?} <- normalize_property(property),
         {:ok, type} <- property_type(projected_property) do
      opts = field_options(projected_property, type, MapSet.member?(required, name), nullable?)

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

  defp field_options(property, type, required?, nullable?) do
    [
      type: type,
      required: required?,
      description: property["description"],
      default: property["default"],
      enum: property["enum"],
      nullable: if(nullable?, do: true)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  # Only a single supported type plus an unconstrained null branch is projected.
  # General unions remain unsupported rather than silently losing alternatives.
  defp normalize_property(%{"anyOf" => variants} = property),
    do: normalize_nullable_union(property, "anyOf", variants)

  defp normalize_property(%{"oneOf" => variants} = property) do
    case nullable_branch(variants) do
      {:ok, _branch} -> normalize_nullable_union(property, "oneOf", variants)
      :error -> {:ok, property, false}
    end
  end

  defp normalize_property(%{"type" => types} = property) when is_list(types) do
    case types do
      [type, "null"] when is_binary(type) and type != "null" ->
        {:ok, Map.put(property, "type", type), true}

      ["null", type] when is_binary(type) and type != "null" ->
        {:ok, Map.put(property, "type", type), true}

      _ ->
        {:error, {:unsupported_property_schema, property}}
    end
  end

  defp normalize_property(property), do: {:ok, property, false}

  defp normalize_nullable_union(property, keyword, variants) do
    case nullable_branch(variants) do
      {:ok, branch} ->
        # A branch enum constrains only non-null values. An outer enum instead
        # constrains the whole union, so preserve/intersect it when present.
        branch =
          case branch["enum"] do
            values when is_list(values) -> Map.put(branch, "enum", Enum.uniq(values ++ [nil]))
            _ -> branch
          end

        outer = Map.delete(property, keyword)
        projected = Map.merge(branch, outer)

        projected =
          case {branch["enum"], outer["enum"]} do
            {inner, outer} when is_list(inner) and is_list(outer) ->
              Map.put(projected, "enum", Enum.filter(outer, &(&1 in inner)))

            _ ->
              projected
          end

        {:ok, projected, true}

      :error ->
        {:error, {:unsupported_property_schema, property}}
    end
  end

  defp nullable_branch([%{"type" => "null"} = null, %{} = branch]) when map_size(null) == 1,
    do: {:ok, branch}

  defp nullable_branch([%{} = branch, %{"type" => "null"} = null]) when map_size(null) == 1,
    do: {:ok, branch}

  defp nullable_branch(_variants), do: :error

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

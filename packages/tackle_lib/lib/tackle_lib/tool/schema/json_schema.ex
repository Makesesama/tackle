defmodule Tackle.Lib.Tool.Schema.JsonSchema do
  @moduledoc """
  JSON Schema projection for Tackle.Lib's native tool schema.

  `Tackle.Lib.Tool.definition/1` uses it to compute a tool's `input_schema`
  once, so provider adapters send that JSON Schema as it is instead of
  converting tool schemas themselves. Adapters that take a structured-output
  schema in the keyword form may project it with `to_json_schema/1` too.

  The projection of a field:

    * `:string`, `:integer`, `:boolean`, and `:map` become the JSON Schema
      types `"string"`, `"integer"`, `"boolean"`, and `"object"`; `:float`
      becomes `"number"`; `{:list, type}` becomes an `"array"` whose
      `"items"` are the projection of `type`;
    * `nullable: true` makes the type `[type, "null"]`;
    * `:description`, `:default`, and `:enum` are kept as `"description"`,
      `"default"`, and `"enum"`;
    * `required: true` lists the field in the object's `"required"`, in
      declaration order.
  """

  @type schema :: Tackle.Lib.Tool.Schema.t()

  @doc """
  Projects Tackle.Lib's keyword schema into JSON Schema object form.

  Raises `ArgumentError` for a field of an unknown type; schemas checked by
  `Tackle.Lib.Tool.Schema.validate_schema/1` (as every registered tool's are)
  have none.
  """
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

  defp field_json_schema(opts) do
    type = Keyword.get(opts, :type, :string)

    %{}
    |> Map.merge(type_json_schema(type))
    |> maybe_nullable(Keyword.get(opts, :nullable, false))
    |> maybe_put("description", Keyword.get(opts, :description))
    |> maybe_put("default", Keyword.get(opts, :default))
    |> maybe_put("enum", Keyword.get(opts, :enum))
  end

  defp maybe_nullable(schema, true), do: Map.update!(schema, "type", &[&1, "null"])
  defp maybe_nullable(schema, _nullable), do: schema

  defp type_json_schema(:string), do: %{"type" => "string"}
  defp type_json_schema(:integer), do: %{"type" => "integer"}
  defp type_json_schema(:float), do: %{"type" => "number"}
  defp type_json_schema(:boolean), do: %{"type" => "boolean"}
  defp type_json_schema(:map), do: %{"type" => "object"}

  defp type_json_schema({:list, inner}),
    do: %{"type" => "array", "items" => type_json_schema(inner)}

  defp type_json_schema(type),
    do: raise(ArgumentError, "unknown tool schema type: #{inspect(type)}")

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

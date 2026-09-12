defmodule Tackle.Lib.Tool.Schema.JsonSchema do
  @moduledoc """
  JSON Schema projection and validation for Tackle.Lib's native tool schema.

  This module is intentionally separate from `Tackle.Lib.Tool.Schema` so core Tackle.Lib
  remains format-agnostic. Provider adapters that speak JSON Schema can opt into
  this projection at the adapter boundary.

  Validation is delegated to `JSV` using JSON Schema Draft 2020-12.
  """

  @type schema :: Tackle.Lib.Tool.Schema.t()

  @doc "Projects Tackle.Lib's keyword schema into JSON Schema object form."
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

  @doc "Validates output against a JSON Schema."
  @spec validate_output(map(), term()) :: {:ok, term()} | {:error, String.t()}
  def validate_output(%{} = schema, output) do
    with {:ok, root} <- JSV.build(schema, atoms: false, warnings: :silent),
         {:ok, _validated} <- JSV.validate(stringify_map_keys(output), root, cast: false) do
      {:ok, output}
    else
      {:error, %JSV.ValidationError{} = error} ->
        {:error, "Invalid tool output: #{format_validation_error(error)}"}

      {:error, %JSV.BuildError{} = error} ->
        {:error, "Invalid output schema: #{Exception.message(error)}"}
    end
  end

  @doc "Alias for validator tuples accepted by `Tackle.Lib.Tool.Schema.validate_output/2`."
  @spec validate(map(), term()) :: {:ok, term()} | {:error, String.t()}
  def validate(schema, output), do: validate_output(schema, output)

  defp format_validation_error(error) do
    error
    |> JSV.normalize_error()
    |> Map.fetch!(:details)
    |> Enum.flat_map(&format_detail/1)
    |> Enum.join("; ")
  end

  defp format_detail(detail) do
    path = format_instance_path(detail.instanceLocation)

    Enum.map(detail.errors, &format_message(path, &1))
  end

  defp format_message("$", error), do: error.message
  defp format_message(path, error), do: "#{path} #{error.message}"

  defp format_instance_path("#"), do: "$"

  defp format_instance_path("#/" <> pointer) do
    pointer
    |> String.split("/")
    |> Enum.map_join(".", &unescape_pointer_segment/1)
    |> then(&"$.#{&1}")
  end

  defp unescape_pointer_segment(segment) do
    segment
    |> String.replace("~1", "/")
    |> String.replace("~0", "~")
  end

  defp stringify_map_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_map_keys(value)} end)
  end

  defp stringify_map_keys(list) when is_list(list), do: Enum.map(list, &stringify_map_keys/1)
  defp stringify_map_keys(value), do: value

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

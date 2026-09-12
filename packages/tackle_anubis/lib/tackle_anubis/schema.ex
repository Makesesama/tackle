defmodule Tackle.Anubis.Schema do
  @moduledoc """
  Peri projection for registering Tackle.Lib tools with an Anubis server.

  Kept in the Anubis integration so `Tackle.Lib.Tool.Schema` remains independent of
  any provider/runtime schema format.
  """

  @doc "Projects Tackle.Lib's keyword schema into the Peri-style schema map Anubis expects."
  @spec to_peri(Tackle.Lib.Tool.Schema.t() | map() | nil) :: map() | nil
  def to_peri(nil), do: nil

  def to_peri(schema) when is_list(schema) do
    Map.new(schema, fn {field, opts} -> {field, field_peri_schema(opts)} end)
  end

  def to_peri(schema) when is_map(schema), do: schema

  defp field_peri_schema(opts) do
    base = peri_type(Keyword.get(opts, :type, :string), Keyword.get(opts, :enum))

    with_default =
      case Keyword.fetch(opts, :default) do
        {:ok, default} -> {base, {:default, default}}
        :error -> base
      end

    with_meta =
      case Keyword.get(opts, :description) do
        nil -> with_default
        description -> {:meta, with_default, description: description}
      end

    if Keyword.get(opts, :required, false), do: {:required, with_meta}, else: with_meta
  end

  defp peri_type(type, enum) when is_list(enum), do: {:enum, enum, type: peri_enum_type(type)}
  defp peri_type(:float, _enum), do: :float
  # Some MCP clients serialize nested object arguments as JSON strings even
  # when the tool schema advertises an object. Accept either at the Anubis
  # boundary; Tackle.Anubis decodes string values with the configured
  # Tackle.Lib.JSON behaviour before core Tackle.Lib validation runs.
  defp peri_type(:map, _enum), do: {:either, {:map, :string}}
  defp peri_type({:list, inner}, _enum), do: {:list, peri_type(inner, nil)}
  defp peri_type({:array, inner}, _enum), do: {:list, peri_type(inner, nil)}
  defp peri_type(type, _enum) when type in [:string, :integer, :boolean], do: type
  defp peri_type(_type, _enum), do: :string

  defp peri_enum_type(type) when type in [:string, :integer, :float, :boolean], do: type
  defp peri_enum_type(_type), do: :string
end

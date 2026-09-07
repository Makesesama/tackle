defmodule Tackle.Tool.Schema do
  @moduledoc """
  Format-agnostic tool schema helpers.

  Tackle's core schema is a small Elixir keyword-list shape used for local tool
  argument validation/coercion. Wire-format projections such as JSON Schema or
  Peri live outside this module so provider adapters can choose their own
  representation without making Tackle's core contract format-specific.

  The canonical normalized argument map uses **string keys** because tool calls
  commonly arrive from JSON providers with string-keyed arguments. Host adapters
  that prefer atoms can convert after this boundary.
  """

  @type primitive_type :: :string | :integer | :float | :boolean | :map
  @type schema_type :: primitive_type() | {:list, schema_type()} | {:array, schema_type()}
  @type field_options :: keyword()
  @type t :: keyword(field_options())
  @type validation_error :: %{field: String.t(), message: String.t()}
  @type output_schema :: t() | {module(), term()} | map() | nil

  @doc "Validates and coerces raw tool arguments according to `schema`."
  @spec validate(t(), map() | nil) :: {:ok, map()} | {:error, [validation_error()]}
  def validate(schema, args) when is_map(args) or is_nil(args) do
    args = args || %{}

    {normalized, errors} =
      Enum.reduce(schema, {%{}, []}, fn {field, opts}, acc ->
        validate_field(args, to_string(field), opts, acc)
      end)

    if errors == [] do
      {:ok, normalized}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  @doc "Raises if validation fails. Useful for tests and adapters."
  @spec validate!(t(), map() | nil) :: map()
  def validate!(schema, args) do
    case validate(schema, args) do
      {:ok, normalized} -> normalized
      {:error, errors} -> raise ArgumentError, format_errors(errors)
    end
  end

  @doc "Returns a provider-neutral, serializable definition map."
  @spec definition(String.t(), String.t(), t(), keyword()) :: map()
  def definition(name, description, input_schema, opts \\ []) do
    %{
      name: name,
      description: description,
      input_schema: normalize_schema(input_schema),
      output_schema: opts[:output_schema]
    }
  end

  @doc """
  Validates a tool output value.

  Keyword schemas use Tackle's native validator. `{validator, schema}` delegates
  validation to a host/provider validator module that implements
  `validate_output/2` or `validate/2`. Map schemas are treated as opaque external
  schemas and are not validated by core Tackle.
  """
  @spec validate_output(output_schema(), term()) :: {:ok, term()} | {:error, String.t()}
  def validate_output(nil, output), do: {:ok, output}

  def validate_output(schema, output) when is_list(schema) do
    case validate(schema, output) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, errors} -> {:error, format_output_errors(errors)}
    end
  end

  def validate_output({validator, schema}, output) when is_atom(validator) do
    cond do
      function_exported?(validator, :validate_output, 2) ->
        validator.validate_output(schema, output)

      function_exported?(validator, :validate, 2) ->
        validator.validate(schema, output)

      true ->
        {:error, "Invalid output validator: #{inspect(validator)}"}
    end
  end

  def validate_output(%{} = _opaque_external_schema, output), do: {:ok, output}

  @doc "Formats validation errors for tool-result feedback."
  @spec format_errors([validation_error()]) :: String.t()
  def format_errors(errors) do
    errors
    |> Enum.map_join("; ", fn %{field: field, message: message} -> "#{field}: #{message}" end)
    |> then(&"Invalid tool arguments: #{&1}")
  end

  defp format_output_errors(errors) do
    errors
    |> Enum.map_join("; ", fn %{field: field, message: message} -> "#{field}: #{message}" end)
    |> then(&"Invalid tool output: #{&1}")
  end

  @doc false
  @spec normalize_schema(t()) :: [map()]
  def normalize_schema(schema) do
    Enum.map(schema, fn {field, opts} ->
      %{
        name: to_string(field),
        type: format_type(Keyword.get(opts, :type, :string)),
        required: Keyword.get(opts, :required, false),
        description: Keyword.get(opts, :description),
        default: Keyword.get(opts, :default),
        enum: Keyword.get(opts, :enum)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
  end

  defp validate_field(args, field, opts, {acc, errors}) do
    case fetch_arg(args, field) do
      {:ok, value} -> normalize_present_field(acc, errors, field, opts, value)
      :error -> put_default_or_missing(acc, errors, field, opts)
    end
  end

  defp normalize_present_field(acc, errors, field, opts, value) do
    case coerce_value(value, Keyword.get(opts, :type, :string), opts) do
      {:ok, coerced} -> {Map.put(acc, field, coerced), errors}
      {:error, message} -> {acc, [%{field: field, message: message} | errors]}
      :drop -> put_default_or_missing(acc, errors, field, opts)
    end
  end

  defp fetch_arg(args, field) do
    atom_field = safe_existing_atom(field)

    cond do
      Map.has_key?(args, field) -> {:ok, Map.get(args, field)}
      atom_field && Map.has_key?(args, atom_field) -> {:ok, Map.get(args, atom_field)}
      true -> :error
    end
  end

  defp safe_existing_atom(field) do
    String.to_existing_atom(field)
  rescue
    ArgumentError -> nil
  end

  defp put_default_or_missing(acc, errors, field, opts) do
    cond do
      Keyword.has_key?(opts, :default) ->
        {Map.put(acc, field, Keyword.fetch!(opts, :default)), errors}

      Keyword.get(opts, :required, false) ->
        {acc, [%{field: field, message: "is required"} | errors]}

      true ->
        {acc, errors}
    end
  end

  defp coerce_value(nil, _type, _opts), do: :drop
  defp coerce_value("", _type, _opts), do: :drop

  defp coerce_value(value, type, opts) do
    with {:ok, value} <- coerce_type(value, type),
         :ok <- validate_enum(value, opts) do
      {:ok, value}
    end
  end

  defp coerce_type(value, :string) when is_binary(value), do: {:ok, value}
  defp coerce_type(value, :string), do: {:ok, to_string(value)}

  defp coerce_type(value, :integer) when is_integer(value), do: {:ok, value}

  defp coerce_type(value, :integer) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, "must be an integer"}
    end
  end

  defp coerce_type(_value, :integer), do: {:error, "must be an integer"}

  defp coerce_type(value, :float) when is_float(value) or is_integer(value), do: {:ok, value}

  defp coerce_type(value, :float) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> {:ok, float}
      _ -> {:error, "must be a number"}
    end
  end

  defp coerce_type(_value, :float), do: {:error, "must be a number"}

  defp coerce_type(value, :boolean) when is_boolean(value), do: {:ok, value}
  defp coerce_type("true", :boolean), do: {:ok, true}
  defp coerce_type("false", :boolean), do: {:ok, false}
  defp coerce_type(_value, :boolean), do: {:error, "must be a boolean"}

  defp coerce_type(value, :map) when is_map(value), do: {:ok, value}
  defp coerce_type(_value, :map), do: {:error, "must be an object"}

  defp coerce_type(value, {:list, inner_type}) when is_list(value),
    do: coerce_array(value, inner_type)

  defp coerce_type(value, {:array, inner_type}) when is_list(value),
    do: coerce_array(value, inner_type)

  defp coerce_type(_value, {:list, _inner_type}), do: {:error, "must be an array"}
  defp coerce_type(_value, {:array, _inner_type}), do: {:error, "must be an array"}
  defp coerce_type(value, _unknown_type), do: {:ok, value}

  defp coerce_array(value, inner_type) do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case coerce_type(item, inner_type) do
        {:ok, coerced} -> {:cont, {:ok, [coerced | acc]}}
        {:error, message} -> {:halt, {:error, "list item #{message}"}}
      end
    end)
    |> case do
      {:ok, coerced} -> {:ok, Enum.reverse(coerced)}
      error -> error
    end
  end

  defp validate_enum(value, opts) do
    case Keyword.get(opts, :enum) do
      nil ->
        :ok

      values when is_list(values) ->
        if value in values, do: :ok, else: {:error, "must be one of #{Enum.join(values, ", ")}"}
    end
  end

  defp format_type({:list, inner}), do: "array<#{format_type(inner)}>"
  defp format_type({:array, inner}), do: "array<#{format_type(inner)}>"
  defp format_type(:float), do: "number"
  defp format_type(type), do: to_string(type)
end

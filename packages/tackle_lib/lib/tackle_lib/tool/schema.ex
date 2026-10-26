defmodule Tackle.Lib.Tool.Schema do
  @moduledoc """
  Format-agnostic tool schema helpers.

  Tackle.Lib's core schema is a small Elixir keyword-list shape used for local tool
  argument validation/coercion. Wire-format projections live outside this
  module: `Tackle.Lib.Tool.Schema.JsonSchema` projects it into the JSON Schema
  of a tool's definition (`Tackle.Lib.Tool.definition/1`), which provider
  adapters send as it is, and integrations may add their own (for example,
  Peri in `tackle_anubis`).

  The canonical normalized argument map uses **string keys** because tool calls
  commonly arrive from JSON providers with string-keyed arguments. Host adapters
  that prefer atoms can convert after this boundary.

  ## Fields

  A schema is a keyword list of `{field_name, options}` with atom field names.
  The options are:

    * `:type` - one of `t:schema_type/0`; defaults to `:string`;
    * `:required` - `true` when the field must be present;
    * `:default` - the value used when the field is absent;
    * `:description` - a string for the model;
    * `:enum` - a list of the allowed values, compared with `in` after
      coercion, so `1` and `1.0` are different values;
    * `:nullable` - `true` to accept and preserve an explicit `nil`. This is
      independent of `required: true`, which still requires the key to be
      present. Enums on nullable fields must include `nil` to allow it.

  `validate_schema/1` checks a schema against these rules. `Tackle.Lib.Tool`'s
  DSL runs it when a tool compiles, and `Tackle.Lib.Tool.Registry.new/1` when
  a tool is registered, so an unknown type or option is an error rather than
  being accepted silently.

  ## Coercion

  Arguments are coerced to their field's type where that is unambiguous:

    * `:string` accepts strings, including `""`, and turns numbers and
      booleans into their string form; anything else is invalid;
    * `:integer` accepts integers and strings that parse as one;
    * `:float` accepts numbers and strings that parse as one, and always
      returns a float (`1` becomes `1.0`);
    * `:boolean` accepts booleans and `"true"`/`"false"`;
    * `:map` accepts maps and strings holding a JSON object (some providers
      send nested objects as JSON strings), decoded with Elixir's `JSON`,
      including inside `{:list, :map}`;
    * `{:list, type}` accepts lists and coerces each item.

  An absent field, an explicit `nil` on a field that is not nullable, and
  `""` on a field that is not a `:string` all count as absent: the field gets
  its default, or a required field reports `"is required"`. On a `:string`
  field `""` is a value like any other string.
  """

  @type primitive_type :: :string | :integer | :float | :boolean | :map
  @type schema_type :: primitive_type() | {:list, schema_type()}
  @type field_options :: keyword()
  @type t :: keyword(field_options())

  @typedoc """
  A validation failure of one field, or of the whole value when `field` is
  `nil` (for example, an output that is not a map).
  """
  @type validation_error :: %{field: String.t() | nil, message: String.t()}
  @type output_schema :: t() | {module(), term()} | map() | nil

  @primitive_types [:string, :integer, :float, :boolean, :map]
  @field_options [:type, :required, :default, :description, :enum, :nullable]

  @doc """
  Validates and coerces raw tool arguments according to `schema`.

  `nil` arguments are treated as an empty map; any other value that is not a
  map is a validation error.
  """
  @spec validate(t(), term()) :: {:ok, map()} | {:error, [validation_error()]}
  def validate(schema, nil), do: validate(schema, %{})

  def validate(schema, args) when is_map(args) do
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

  def validate(_schema, _args), do: {:error, [%{field: nil, message: "must be an object"}]}

  @doc """
  Checks that `schema` is a valid keyword schema: a keyword list of fields
  with atom names, each declared once, with known options (see the module
  docs) and a known type.

  Returns `:ok` or `{:error, message}` naming the offending field.

      iex> Tackle.Lib.Tool.Schema.validate_schema(path: [type: :string, required: true])
      :ok

      iex> Tackle.Lib.Tool.Schema.validate_schema(path: [type: :text])
      {:error, "field :path has unknown type :text; known types are :string, :integer, :float, :boolean, :map, and {:list, type}"}
  """
  @spec validate_schema(term()) :: :ok | {:error, String.t()}
  def validate_schema(schema) when is_list(schema) do
    schema
    |> Enum.reduce_while(MapSet.new(), fn field, seen ->
      case check_field(field, seen) do
        {:ok, name} -> {:cont, MapSet.put(seen, name)}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:error, message} -> {:error, message}
      _seen -> :ok
    end
  end

  def validate_schema(schema),
    do: {:error, "schema must be a keyword list of fields, got: #{inspect(schema)}"}

  @doc """
  Validates a tool output value.

  Keyword schemas use Tackle.Lib's native validator, which requires the output
  to be a map (`nil` included is not). `{validator, schema}` delegates
  validation to a host/provider validator module that implements
  `validate_output/2` or `validate/2`. Map schemas are treated as opaque external
  schemas and are not validated by core Tackle.Lib.
  """
  @spec validate_output(output_schema(), term()) :: {:ok, term()} | {:error, String.t()}
  def validate_output(nil, output), do: {:ok, output}

  def validate_output(schema, output) when is_list(schema) and is_map(output) do
    case validate(schema, output) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, errors} -> {:error, format_output_errors(errors)}
    end
  end

  def validate_output(schema, _output) when is_list(schema),
    do: {:error, format_output_errors([%{field: nil, message: "must be an object"}])}

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

  @doc """
  Formats validation errors for tool-result feedback.

  The text names only schema fields and their constraints, never the values
  that failed, so it is safe to show to the model.
  """
  @spec format_errors([validation_error()]) :: String.t()
  def format_errors(errors), do: "Invalid tool arguments: " <> join_errors(errors)

  defp format_output_errors(errors), do: "Invalid tool output: " <> join_errors(errors)

  defp join_errors(errors) do
    Enum.map_join(errors, "; ", fn
      %{field: nil, message: message} -> message
      %{field: field, message: message} -> "#{field}: #{message}"
    end)
  end

  # ── Schema checks ─────────────────────────────────────────────────────

  defp check_field({name, opts}, seen) when is_atom(name) and is_list(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, "field #{inspect(name)} options must be a keyword list"}

      MapSet.member?(seen, name) ->
        {:error, "field #{inspect(name)} is declared more than once"}

      true ->
        with :ok <- check_options(name, opts), do: {:ok, name}
    end
  end

  defp check_field(field, _seen) do
    {:error, "fields must be {atom_name, keyword_options} pairs, got: #{inspect(field)}"}
  end

  defp check_options(name, opts) do
    case Keyword.keys(opts) -- @field_options do
      [] ->
        check_option_values(name, opts)

      unknown ->
        {:error,
         "field #{inspect(name)} has unknown options #{inspect(unknown)}; " <>
           "known options are #{Enum.map_join(@field_options, ", ", &inspect/1)}"}
    end
  end

  defp check_option_values(name, opts) do
    type = Keyword.get(opts, :type, :string)

    cond do
      not known_type?(type) ->
        {:error,
         "field #{inspect(name)} has unknown type #{inspect(type)}; known types are " <>
           ":string, :integer, :float, :boolean, :map, and {:list, type}"}

      Keyword.get(opts, :required, false) not in [true, false] ->
        {:error, "field #{inspect(name)} option :required must be a boolean"}

      Keyword.get(opts, :nullable, false) not in [true, false] ->
        {:error, "field #{inspect(name)} option :nullable must be a boolean"}

      not optional?(opts, :description, &is_binary/1) ->
        {:error, "field #{inspect(name)} option :description must be a string"}

      not optional?(opts, :enum, &is_list/1) ->
        {:error, "field #{inspect(name)} option :enum must be a list"}

      true ->
        :ok
    end
  end

  # An option that is absent or nil, or whose value passes `check`.
  defp optional?(opts, key, check) do
    case Keyword.get(opts, key) do
      nil -> true
      value -> check.(value)
    end
  end

  defp known_type?(type) when type in @primitive_types, do: true
  defp known_type?({:list, inner}), do: known_type?(inner)
  defp known_type?(_type), do: false

  # ── Validation ────────────────────────────────────────────────────────

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

  defp coerce_value(nil, _type, opts) do
    if Keyword.get(opts, :nullable) == true do
      with :ok <- validate_enum(nil, opts), do: {:ok, nil}
    else
      :drop
    end
  end

  defp coerce_value("", type, _opts) when type != :string, do: :drop

  defp coerce_value(value, type, opts) do
    with {:ok, value} <- coerce_type(value, type),
         :ok <- validate_enum(value, opts) do
      {:ok, value}
    end
  end

  defp coerce_type(value, :string) when is_binary(value), do: {:ok, value}

  defp coerce_type(value, :string) when is_number(value) or is_boolean(value),
    do: {:ok, to_string(value)}

  defp coerce_type(_value, :string), do: {:error, "must be a string"}

  defp coerce_type(value, :integer) when is_integer(value), do: {:ok, value}

  defp coerce_type(value, :integer) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, "must be an integer"}
    end
  end

  defp coerce_type(_value, :integer), do: {:error, "must be an integer"}

  defp coerce_type(value, :float) when is_float(value), do: {:ok, value}
  defp coerce_type(value, :float) when is_integer(value), do: {:ok, value * 1.0}

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

  defp coerce_type(value, :map) when is_binary(value) do
    case JSON.decode(value) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _other -> {:error, "must be an object"}
    end
  end

  defp coerce_type(_value, :map), do: {:error, "must be an object"}

  defp coerce_type(value, {:list, inner_type}) when is_list(value),
    do: coerce_list(value, inner_type)

  defp coerce_type(_value, {:list, _inner_type}), do: {:error, "must be an array"}

  defp coerce_type(_value, type),
    do: raise(ArgumentError, "unknown tool schema type: #{inspect(type)}")

  defp coerce_list(value, inner_type) do
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
end

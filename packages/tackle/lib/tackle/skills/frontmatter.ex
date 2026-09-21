defmodule Tackle.Skills.Frontmatter do
  @moduledoc false

  # A deliberately small YAML subset parser for `SKILL.md` frontmatter. The
  # Agent Skills specification only needs flat `key: value` entries, quoted
  # scalars, and block scalars, so the harness avoids a full YAML dependency.
  #
  # Unknown keys are preserved so callers can decide what to use. A document
  # without a leading `---` fence has no frontmatter and parses to an empty map.

  @type error_reason :: :unterminated_frontmatter | :malformed_frontmatter
  @type parsed :: {:ok, map()} | {:error, error_reason()}
  @type document :: %{frontmatter: map(), body: String.t()}

  @key_regex ~r/^([A-Za-z0-9_.-]+):[ \t]?(.*)$/
  @block_regex ~r/^[|>][+-]?\d*$/

  @spec parse(String.t()) :: parsed()
  def parse(contents) when is_binary(contents) do
    with {:ok, document} <- parse_document(contents) do
      {:ok, document.frontmatter}
    end
  end

  @doc false
  @spec parse_document(String.t()) :: {:ok, document()} | {:error, error_reason()}
  def parse_document(contents) when is_binary(contents) do
    contents = contents |> strip_bom() |> normalize_newlines()

    with {:ok, lines, body} <- extract(contents),
         {:ok, frontmatter} <- to_map({:ok, lines}) do
      {:ok, %{frontmatter: frontmatter, body: body}}
    end
  end

  defp extract(contents) do
    case String.split(contents, "\n") do
      ["---" | rest] ->
        case Enum.split_while(rest, &(String.trim(&1) != "---")) do
          {_lines, []} -> {:error, :unterminated_frontmatter}
          {lines, [_closing | body]} -> {:ok, lines, body |> Enum.join("\n") |> String.trim()}
        end

      _ ->
        {:ok, [], String.trim(contents)}
    end
  end

  defp to_map({:ok, lines}) do
    with {:ok, entries} <- entries(lines) do
      {:ok, Map.new(entries, fn {key, values} -> {key, value(values)} end)}
    end
  end

  defp entries(lines) do
    lines
    |> Enum.reduce_while({:ok, []}, &entry/2)
    |> case do
      {:ok, entries} -> {:ok, :lists.reverse(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp entry(line, {:ok, entries}) do
    cond do
      blank?(line) ->
        {:cont, {:ok, entries}}

      comment?(line) ->
        {:cont, {:ok, entries}}

      leading_space?(line) ->
        case entries do
          [{key, values} | rest] -> {:cont, {:ok, [{key, [String.trim(line) | values]} | rest]}}
          [] -> {:halt, {:error, :malformed_frontmatter}}
        end

      true ->
        case split_key(line) do
          {:ok, key, value} -> {:cont, {:ok, [{key, [value]} | entries]}}
          :error -> {:halt, {:error, :malformed_frontmatter}}
        end
    end
  end

  defp entry(_line, {:error, reason}), do: {:halt, {:error, reason}}

  defp value(values) do
    [first | rest] = Enum.reverse(values)

    cond do
      block_marker?(first) -> join(rest)
      rest != [] -> join([first | rest])
      true -> scalar(first)
    end
  end

  defp join(lines) do
    lines
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> String.trim()
  end

  defp scalar(value) do
    value = String.trim(value)

    cond do
      unterminated_flow?(value) -> nil
      quoted?(value, ?") -> unquote_json(value)
      quoted?(value, ?') -> value |> String.slice(1..-2//1) |> String.replace("''", "'")
      value in ["true", "True", "TRUE"] -> true
      value in ["false", "False", "FALSE"] -> false
      value in ["null", "Null", "NULL", "~"] -> nil
      true -> value
    end
  end

  # A flow collection that never closes is the common malformed-frontmatter
  # mistake; treat it as missing so the skill is skipped rather than loaded
  # with a nonsense description.
  defp unterminated_flow?(<<"[", _rest::binary>> = value), do: not String.ends_with?(value, "]")
  defp unterminated_flow?(<<"{", _rest::binary>> = value), do: not String.ends_with?(value, "}")
  defp unterminated_flow?(_value), do: false

  defp split_key(line) do
    case Regex.run(@key_regex, line) do
      [_, key, value] -> {:ok, key, value}
      _other -> :error
    end
  end

  defp block_marker?(value), do: Regex.match?(@block_regex, value)

  defp quoted?(value, quote) do
    case value do
      <<^quote, _rest::binary>> -> byte_size(value) >= 2 and :binary.last(value) == quote
      _other -> false
    end
  end

  defp unquote_json(value) do
    case JSON.decode(value) do
      {:ok, decoded} when is_binary(decoded) -> decoded
      _other -> String.slice(value, 1..-2//1)
    end
  end

  defp blank?(line), do: String.trim(line) == ""

  defp comment?(line), do: line |> String.trim_leading() |> String.starts_with?("#")

  defp leading_space?(<<char, _rest::binary>>), do: char in [?\s, ?\t]
  defp leading_space?(_line), do: false

  defp normalize_newlines(contents) do
    contents
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(contents), do: contents
end

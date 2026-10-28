defmodule YamlFrontmatter do
  @moduledoc """
  A deliberately small parser for the YAML front matter of Markdown files,
  such as `SKILL.md` files, agent definitions, or rule files.

  It supports what such files need, flat `key: value` entries, quoted
  scalars, booleans, flow lists, comments, and block scalars, rather than
  full YAML, so it has no dependencies. Unknown keys are preserved
  so callers can decide what to use. A document without a leading `---`
  fence has no front matter and parses to an empty map.

  Lists are returned as the text the file has; `list/1` reads such a value
  as a list of strings.
  """

  @type error_reason :: :unterminated_frontmatter | :malformed_frontmatter
  @type parsed :: {:ok, map()} | {:error, error_reason()}
  @type document :: %{frontmatter: map(), body: String.t()}

  @key_regex ~r/^([A-Za-z0-9_.-]+):[ \t]?(.*)$/
  @block_regex ~r/^[|>][+-]?\d*$/

  @doc "Parses the front matter of `contents`."
  @spec parse(String.t()) :: parsed()
  def parse(contents) when is_binary(contents) do
    with {:ok, document} <- parse_document(contents) do
      {:ok, document.frontmatter}
    end
  end

  @doc "Parses `contents` into its front matter and the body after it."
  @spec parse_document(String.t()) :: {:ok, document()} | {:error, error_reason()}
  def parse_document(contents) when is_binary(contents) do
    contents = contents |> strip_bom() |> normalize_newlines()

    with {:ok, lines, body} <- extract(contents),
         {:ok, frontmatter} <- to_map({:ok, lines}) do
      {:ok, %{frontmatter: frontmatter, body: body}}
    end
  end

  @doc """
  Reads a front matter value as a list of strings.

  Accepts a flow list (`[a, "b", 'c']`), a block list (`- item` lines, as
  `parse/1` returns them), or items separated by commas or newlines. Items
  may be quoted like scalars. Commas inside quotes, braces, or brackets do
  not separate items, so globs such as `lib/*.{ex,exs}` stay whole. Empty
  items are dropped, so an empty value is an empty list.

  An unterminated quote, text after a closing quote, a block list line
  without `-`, or a value that is not a string returns
  `{:error, :malformed_list}`.

      iex> YamlFrontmatter.list(~s(["read", 'bash']))
      {:ok, ["read", "bash"]}

      iex> YamlFrontmatter.list("- read\\n- bash")
      {:ok, ["read", "bash"]}

      iex> YamlFrontmatter.list("lib/*.{ex,exs}, test/**")
      {:ok, ["lib/*.{ex,exs}", "test/**"]}
  """
  @spec list(term()) :: {:ok, [String.t()]} | {:error, :malformed_list}
  def list(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      String.starts_with?(value, "[") and String.ends_with?(value, "]") ->
        value |> String.slice(1..-2//1) |> items([])

      block_item?(value) ->
        block_items(value)

      true ->
        items(value, [])
    end
  end

  def list(_value), do: {:error, :malformed_list}

  defp block_item?(line), do: line == "-" or String.starts_with?(line, ["- ", "-\t"])

  defp block_items(value) do
    value
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      with true <- block_item?(line),
           {:ok, [item]} <- line |> String.slice(1..-1//1) |> items([]) do
        {:cont, {:ok, [item | acc]}}
      else
        {:ok, []} -> {:cont, {:ok, acc}}
        _other -> {:halt, {:error, :malformed_list}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  # Items separated by commas or newlines; quoted items are unquoted.
  defp items(text, acc) do
    case String.trim_leading(text) do
      "" ->
        {:ok, acc |> Enum.reject(&(&1 == "")) |> Enum.reverse()}

      <<quote, _rest::binary>> = text when quote in [?", ?'] ->
        with {:ok, item, rest} <- quoted_item(text, quote),
             {:ok, rest} <- after_quoted(rest) do
          items(rest, [item | acc])
        end

      text ->
        {item, rest} = plain_item(text, 0, [])
        items(rest, [String.trim(item) | acc])
    end
  end

  defp quoted_item(<<?", rest::binary>>, ?") do
    with {:ok, length} <- closing_double_quote(rest, 0),
         {:ok, item} when is_binary(item) <-
           JSON.decode(~s(") <> binary_part(rest, 0, length + 1)) do
      {:ok, item, binary_part(rest, length + 1, byte_size(rest) - length - 1)}
    else
      _other -> {:error, :malformed_list}
    end
  end

  defp quoted_item(<<?', rest::binary>>, ?'), do: single_quoted(rest, [])

  # The byte offset of the closing `"`, skipping escaped characters.
  defp closing_double_quote(<<?\\, _escaped, rest::binary>>, offset),
    do: closing_double_quote(rest, offset + 2)

  defp closing_double_quote(<<?", _rest::binary>>, offset), do: {:ok, offset}

  defp closing_double_quote(<<_char, rest::binary>>, offset),
    do: closing_double_quote(rest, offset + 1)

  defp closing_double_quote(_end, _offset), do: :error

  defp single_quoted("''" <> rest, acc), do: single_quoted(rest, ["'" | acc])

  defp single_quoted("'" <> rest, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp single_quoted(<<char, rest::binary>>, acc), do: single_quoted(rest, [char | acc])
  defp single_quoted("", _acc), do: {:error, :malformed_list}

  # After a quoted item comes the end or a separator.
  defp after_quoted(rest) do
    case String.replace(rest, ~r/\A[ \t]+/, "") do
      "" -> {:ok, ""}
      <<separator, rest::binary>> when separator in [?,, ?\n] -> {:ok, rest}
      _other -> {:error, :malformed_list}
    end
  end

  # Plain text up to a separator outside braces and brackets.
  defp plain_item("", _depth, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}

  defp plain_item(<<separator, rest::binary>>, 0, acc) when separator in [?,, ?\n],
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp plain_item(<<char, rest::binary>>, depth, acc) do
    depth =
      cond do
        char in [?{, ?[] -> depth + 1
        char in [?}, ?]] -> max(depth - 1, 0)
        true -> depth
      end

    plain_item(rest, depth, [char | acc])
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

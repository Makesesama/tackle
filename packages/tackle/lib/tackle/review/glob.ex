defmodule Tackle.Review.Glob do
  @moduledoc """
  Gitignore-style path globs for review exclusions and rule scopes.

  Patterns match repository-relative paths with `/` separators:

    * `*` matches any characters except `/`, `?` one such character;
    * `**` matches across directories: `**/` is zero or more leading
      directories, a trailing `/**` everything below a directory;
    * `[abc]`, `[a-z]` and `[!abc]` match one character of a class;
    * `{a,b}` matches either alternative;
    * a pattern without a `/` matches the file name at any depth
      (`*.lock` matches `mix.lock` and `assets/yarn.lock`);
    * a pattern ending in `/` matches everything below a directory of that
      name (`deps/` matches `deps/x.ex` and `apps/web/deps/x.ex`);
    * a leading `/` anchors the pattern at the repository root.
  """

  @typedoc "A compiled glob."
  @opaque t :: Regex.t()

  @doc """
  Compiles a glob, returning `{:error, message}` for unbalanced braces or an
  unterminated character class.
  """
  @spec compile(String.t()) :: {:ok, t()} | {:error, String.t()}
  def compile(pattern) when is_binary(pattern) do
    {anchored?, body} =
      case pattern do
        "/" <> rest -> {true, rest}
        rest -> {String.contains?(String.trim_trailing(rest, "/"), "/"), rest}
      end

    {body, directory?} =
      if String.ends_with?(body, "/"),
        do: {String.trim_trailing(body, "/"), true},
        else: {body, false}

    with :ok <- validate(body),
         {:ok, source} <- translate(body, 0, []) do
      prefix = if anchored?, do: "", else: "(?:.*/)?"
      suffix = if directory?, do: "/.*", else: ""

      case Regex.compile("\\A" <> prefix <> source <> suffix <> "\\z", "su") do
        {:ok, regex} -> {:ok, regex}
        {:error, _reason} -> {:error, "invalid pattern"}
      end
    end
  end

  @doc "Compiles a list of globs, failing on the first invalid one."
  @spec compile_all([String.t()]) ::
          {:ok, [t()]} | {:error, {:invalid_glob, String.t(), String.t()}}
  def compile_all(patterns) when is_list(patterns) do
    Enum.reduce_while(patterns, {:ok, []}, fn pattern, {:ok, acc} ->
      case compile(pattern) do
        {:ok, glob} -> {:cont, {:ok, [glob | acc]}}
        {:error, message} -> {:halt, {:error, {:invalid_glob, pattern, message}}}
      end
    end)
    |> case do
      {:ok, globs} -> {:ok, Enum.reverse(globs)}
      error -> error
    end
  end

  @doc "Returns whether a compiled glob, or any of a list of them, matches `path`."
  @spec match?(t() | [t()], String.t()) :: boolean()
  def match?(globs, path) when is_list(globs), do: Enum.any?(globs, &__MODULE__.match?(&1, path))
  def match?(glob, path) when is_binary(path), do: Regex.match?(glob, path)

  defp validate(""), do: {:error, "pattern is empty"}
  defp validate(_body), do: :ok

  defp translate("", 0, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
  defp translate("", _depth, _acc), do: {:error, "unbalanced {"}

  defp translate("**/" <> rest, depth, acc), do: translate(rest, depth, ["(?:.*/)?" | acc])
  defp translate("/**", depth, acc), do: translate("", depth, ["(?:/.*)?" | acc])
  defp translate("**" <> rest, depth, acc), do: translate(rest, depth, [".*" | acc])
  defp translate("*" <> rest, depth, acc), do: translate(rest, depth, ["[^/]*" | acc])
  defp translate("?" <> rest, depth, acc), do: translate(rest, depth, ["[^/]" | acc])
  defp translate("{" <> rest, depth, acc), do: translate(rest, depth + 1, ["(?:" | acc])
  defp translate("}" <> _rest, 0, _acc), do: {:error, "unbalanced }"}
  defp translate("}" <> rest, depth, acc), do: translate(rest, depth - 1, [")" | acc])
  defp translate("," <> rest, depth, acc) when depth > 0, do: translate(rest, depth, ["|" | acc])

  defp translate("[" <> rest, depth, acc) do
    case class(rest) do
      {:ok, source, rest} -> translate(rest, depth, [source | acc])
      :error -> {:error, "unterminated ["}
    end
  end

  defp translate(<<char::utf8, rest::binary>>, depth, acc),
    do: translate(rest, depth, [Regex.escape(<<char::utf8>>) | acc])

  # Classes never match the directory separator.
  defp class("!" <> rest), do: class_body(rest, ["[^/"])
  defp class(rest), do: class_body(rest, ["["])

  defp class_body("]" <> rest, acc),
    do: {:ok, IO.iodata_to_binary(Enum.reverse(["]" | acc])), rest}

  defp class_body("", _acc), do: :error
  defp class_body("-" <> rest, acc), do: class_body(rest, ["-" | acc])

  defp class_body(<<char::utf8, rest::binary>>, acc),
    do: class_body(rest, [Regex.escape(<<char::utf8>>) | acc])
end

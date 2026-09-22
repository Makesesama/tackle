defmodule Tackle.Web.Highlight do
  @moduledoc """
  Highlights source code and splits it into per-line HTML fragments.

  A whole blob is highlighted in one pass, so lexer state that spans lines
  (heredocs, block comments, multi-line strings) is tracked correctly. Splitting
  the result afterwards is what lets the UI place a fragment on the exact diff
  line it came from.

  The highlighter is Lumis, a tree-sitter NIF. Its `:language` option accepts a
  filename or path, so the grammar is inferred from the extension; unknown
  extensions fall back to plain text.
  """

  @line_pattern ~r/<div class="l-line" data-line="(\d+)">(.*?)<\/div>/s

  @default_theme "github_light"

  @doc """
  Highlights `source` as `path` and returns `%{line_number => html}`.

  Line numbers are 1-based and match the file's own numbering, so a fragment can
  be looked up by the line number a diff reports. Returns an empty map when
  highlighting is unavailable; diff lines then render as escaped plain text.
  """
  @spec lines(String.t(), Path.t()) :: %{pos_integer() => String.t()}
  def lines(source, path) do
    case Lumis.highlight(source, formatter: {:html_inline, language: path, theme: theme()}) do
      {:ok, html} -> split_lines(html)
      {:error, _reason} -> %{}
    end
  rescue
    # A missing or panicked NIF can raise instead of returning an error tuple.
    _error in [Lumis.HighlightError, ErlangError] -> %{}
  end

  @doc """
  Escapes `source` without highlighting it.

  Used for lines the highlighter could not cover: a blob that is missing, binary
  or written in an unknown language still has to render as text.
  """
  @spec plain(String.t()) :: String.t()
  def plain(source) do
    source
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # Each line arrives as its own <div>; the content keeps the newline that
  # ended the line, which would render as a blank line inside the UI row.
  @doc false
  @spec split_lines(String.t()) :: %{pos_integer() => String.t()}
  def split_lines(html) do
    @line_pattern
    |> Regex.scan(html)
    |> Map.new(fn [_match, number, content] ->
      {String.to_integer(number), String.trim_trailing(content, "\n")}
    end)
  end

  defp theme do
    Application.get_env(:tackle_web, :highlight_theme, @default_theme)
  end
end

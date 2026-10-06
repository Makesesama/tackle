defmodule Tackle.CLI.TUI.Highlight do
  @moduledoc """
  Syntax highlighting for tool cards and fenced code.

  Lumis — the same tree-sitter highlighter the web app uses — resolves a
  Neovim theme to ANSI truecolor escapes through its `:terminal` formatter;
  this module parses those back into per-line token runs of
  `%ExRatatui.Style{}` so renderers can paint them on their own surfaces. Like
  `Tackle.Web.Highlight`, a whole blob is highlighted in one pass and split
  afterwards, so lexer state that spans lines (heredocs, block comments,
  multi-line strings) is tracked correctly, and a fragment can be looked up
  by the line number a diff reports.

  A run without token styling is `nil`, so a caller falls back to its own
  base style instead of repainting plain text. Highlighting is best-effort
  and never fails a render: a missing NIF, a parser that cannot be loaded,
  or `config :tackle_cli, :highlight, false` yields an empty map and the
  card renders plain text.

  Cards re-render on every transcript refresh, so results are memoized per
  `{theme, path, source}`. The cache is bounded and cleared wholesale once
  it grows past its limit; a racing reader at worst re-highlights.
  """

  alias ExRatatui.Style
  alias Tackle.CLI.TUI.Theme

  @escape ~r/\e\[[0-9;]*m/

  @default_themes %{dark: "github_dark", light: "github_light"}
  @cache_table :tackle_cli_highlight_cache
  @cache_limit 64

  @typedoc "One token run: `text` with its style, or `nil` when unstyled."
  @type run :: {String.t(), Style.t() | nil}

  @doc """
  Highlights `source` as `path` and returns `%{line_number => [run()]}`.

  Line numbers are 1-based and match the source's own numbering, so a run
  can be looked up by the line number a diff reports. Returns an empty map
  when highlighting is unavailable; lines then render as plain text.
  """
  @spec lines(String.t(), Path.t() | nil) :: %{pos_integer() => [run()]}
  def lines(source, path) when is_binary(source) do
    if Application.get_env(:tackle_cli, :highlight, true),
      do: cached(source, path),
      else: %{}
  end

  defp cached(source, path) do
    key = {theme(), path, source}
    ensure_cache()

    case :ets.lookup(@cache_table, key) do
      [{^key, runs}] ->
        runs

      [] ->
        runs = highlight_lines(source, path)
        cache_put(key, runs)
        runs
    end
  end

  defp highlight_lines(source, path) do
    source_lines = String.split(source, "\n", trim: false)

    case backend().highlight(source, formatter: {:terminal, language: path, theme: theme()}) do
      {:ok, ansi} -> split_lines(ansi, source_lines)
      _error -> %{}
    end
  rescue
    # A missing or panicked NIF can raise instead of returning an error tuple.
    _error in [Lumis.HighlightError, ErlangError] -> %{}
  end

  # Each rendered line must match the source line it claims to cover; a
  # highlighter that reflows or drops content loses the alignment a diff
  # relies on, so only verified lines carry styling.
  defp split_lines(ansi, source_lines) do
    run_lines = String.split(ansi, "\n", trim: false)

    if length(run_lines) == length(source_lines) do
      source_lines
      |> Enum.zip(run_lines)
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {{source_line, ansi_line}, number} ->
        runs = ansi_line |> parse() |> normalize()

        if Enum.map_join(runs, fn {text, _style} -> text end) == source_line,
          do: [{number, runs}],
          else: []
      end)
      |> Map.new()
    else
      %{}
    end
  end

  @doc false
  @spec parse(String.t()) :: [{String.t(), Style.t()}]
  def parse(line) do
    line
    |> String.split(@escape, include_captures: true, trim: false)
    |> Enum.reduce({%{fg: nil, modifiers: []}, []}, fn
      "\e[" <> _ = escape, {state, runs} -> {apply_sgr(escape, state), runs}
      "", acc -> acc
      text, {state, runs} -> {state, [{text, style(state)} | runs]}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # Adjacent runs of equal style are one span; a default style carries no
  # token information, so it becomes `nil` and the caller keeps its base.
  defp normalize(runs) do
    Enum.reduce(runs, [], fn {text, style}, acc ->
      style = if style == %Style{}, do: nil, else: %{style | bg: nil, underline_color: nil}

      case acc do
        [{previous, ^style} | rest] -> [{previous <> text, style} | rest]
        _ -> [{text, style} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp style(%{fg: fg, modifiers: modifiers}), do: %Style{fg: fg, modifiers: modifiers}

  # `ESC[m` is `ESC[0m`; unknown or background parameters are ignored so the
  # row keeps its own fill.
  defp apply_sgr("\e[" <> rest, state) do
    {params, "m"} = String.split_at(rest, -1)
    params |> String.split(";") |> sgr(state)
  end

  defp sgr([], state), do: state

  defp sgr(["" | rest], state), do: sgr(["0" | rest], state)
  defp sgr(["0" | _rest], _state), do: %{fg: nil, modifiers: []}

  defp sgr(["39" | rest], %{modifiers: modifiers}),
    do: sgr(rest, %{fg: nil, modifiers: modifiers})

  defp sgr(["38", "2", r, g, b | rest], state) do
    case rgb(r, g, b) do
      {:ok, fg} -> sgr(rest, %{state | fg: fg})
      :error -> sgr(rest, state)
    end
  end

  defp sgr(["38", "5", index | rest], state) do
    case param(index, 255) do
      {:ok, fg} -> sgr(rest, %{state | fg: {:indexed, fg}})
      :error -> sgr(rest, state)
    end
  end

  # Background and underline-color parameters are consumed, not interpreted:
  # the row owns its fill, and their sub-parameters are not modifiers.
  defp sgr([code | rest], state) when code in ["48", "58"],
    do: sgr(skip_color(rest), state)

  defp sgr([code | rest], %{fg: fg, modifiers: modifiers}) do
    case modifier(code) do
      {modifier, true} -> sgr(rest, %{fg: fg, modifiers: Enum.uniq([modifier | modifiers])})
      {modifier, false} -> sgr(rest, %{fg: fg, modifiers: List.delete(modifiers, modifier)})
      nil -> sgr(rest, %{fg: fg, modifiers: modifiers})
    end
  end

  defp rgb(r, g, b) do
    with {:ok, r} <- param(r, 255),
         {:ok, g} <- param(g, 255),
         {:ok, b} <- param(b, 255),
         do: {:ok, {:rgb, r, g, b}}
  end

  defp param(text, max) do
    case Integer.parse(text) do
      {value, ""} when value >= 0 and value <= max -> {:ok, value}
      _ -> :error
    end
  end

  defp modifier("1"), do: {:bold, true}
  defp modifier("2"), do: {:dim, true}
  defp modifier("3"), do: {:italic, true}
  defp modifier("4"), do: {:underlined, true}
  defp modifier("9"), do: {:crossed_out, true}
  defp modifier("21"), do: {:bold, false}
  defp modifier("22"), do: {:bold, false}
  defp modifier("23"), do: {:italic, false}
  defp modifier("24"), do: {:underlined, false}
  defp modifier("29"), do: {:crossed_out, false}
  defp modifier(_code), do: nil

  defp skip_color(["2", _r, _g, _b | rest]), do: rest
  defp skip_color(["5", _index | rest]), do: rest
  defp skip_color(rest), do: rest

  # The GitHub themes match the diff palette: muted tints on dark, pastels
  # on light. An explicit theme wins over the palette's default.
  defp theme do
    System.get_env("TACKLE_HIGHLIGHT_THEME") ||
      Application.get_env(:tackle_cli, :highlight_theme) ||
      Map.fetch!(@default_themes, Theme.mode())
  end

  defp backend, do: Application.get_env(:tackle_cli, :highlight_backend, Lumis)

  defp ensure_cache do
    if :ets.whereis(@cache_table) == :undefined do
      try do
        :ets.new(@cache_table, [:set, :public, :named_table, read_concurrency: true])
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp cache_put(key, runs) do
    if :ets.info(@cache_table, :size) >= @cache_limit,
      do: :ets.delete_all_objects(@cache_table)

    :ets.insert(@cache_table, {key, runs})
  end
end

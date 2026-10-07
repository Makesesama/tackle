defmodule Tackle.CLI.TUI.Theme do
  @moduledoc """
  Semantic styles for the transcript-first shell.

  Renderers never hard-code terminal colors: they ask for a role such as
  `:muted` or `:surface` and get a `%ExRatatui.Style{}` back. The palette uses
  indexed colors so it is stable on true-color and 256-color terminals and
  degrades to the nearest named color elsewhere.

  `TACKLE_THEME=light` or `dark` selects a palette explicitly. Otherwise
  the background the terminal reports to the OSC 11 query
  (`Tackle.CLI.TUI.TerminalBackground`) is used when available, then the
  final background index in `COLORFGBG`, falling back to dark. The query
  asks the terminal directly, so it works where `COLORFGBG` is absent; the
  index remains a heuristic for terminals that do not answer queries.

  Surface roles always pair
  a foreground with their background, avoiding unreadable inherited text when
  the terminal's colors differ from the selected palette.

  Two kinds of role exist:

    * foreground tones (`:text`, `:muted`, `:subtle`, `:accent`, `:success`,
      `:warning`, `:error`) that carry meaning on their own, and
    * surface roles (`:surface`, `:surface_raised`, `:user_surface`) that paint
      a full-width band behind a block of rows.

  Surfaces are deliberately subtle: they sit a few steps off the terminal
  background so a card reads as a block without competing with the prose.
  `:diff_add` and `:diff_del` are soft foreground accents for counts and `+`/`-`
  markers. Diff rows paint a full-width fill behind added and removed lines
  (`:diff_add_bg` / `:diff_del_bg`, after Codex's diff palette: muted tints on
  dark, GitHub pastels on light); context rows keep the terminal background.
  On light backgrounds the number gutter gets its own opaque, more saturated
  background (`:diff_add_gutter` / `:diff_del_gutter`) so line numbers stay
  readable against the pastel fill; on dark backgrounds the gutter is a dim
  foreground over the fill. Changed tokens inside an otherwise similar line
  use the stronger `:diff_add_inline` and `:diff_del_inline` tints, one step
  more saturated than the line fill so intraline emphasis survives on it.
  All diff colors are indexed, stable on true-color and 256-color terminals;
  on 16-color terminals the terminal itself quantizes them, which can turn a
  fill into a saturated system color. That degradation is accepted rather
  than detected.

  A desaturated blue accent marks activity, selection, and the focused input
  border. Overlay and unfocused input borders stay neutral; warning and error
  colors carry meaning rather than decorating the shell.
  """

  alias ExRatatui.Style
  alias ExRatatui.Widgets.Block

  @type tone ::
          :text
          | :muted
          | :subtle
          | :accent
          | :accent_soft
          | :success
          | :warning
          | :error
          | :surface
          | :surface_raised
          | :code_surface
          | :user_surface
          | :error_surface
          | :selection_surface
          | :diff_add
          | :diff_add_bg
          | :diff_add_gutter
          | :diff_add_inline
          | :diff_del
          | :diff_del_bg
          | :diff_del_gutter
          | :diff_del_inline
          | :diff_context

  @dark_styles %{
    text: %Style{},
    muted: %Style{fg: {:indexed, 246}},
    subtle: %Style{fg: {:indexed, 243}},
    accent: %Style{fg: {:indexed, 110}, modifiers: [:bold]},
    accent_soft: %Style{fg: {:indexed, 110}},
    success: %Style{fg: {:indexed, 114}},
    warning: %Style{fg: {:indexed, 179}},
    error: %Style{fg: {:indexed, 174}},
    surface: %Style{fg: {:indexed, 252}, bg: {:indexed, 235}},
    surface_raised: %Style{fg: {:indexed, 252}, bg: {:indexed, 237}},
    code_surface: %Style{fg: {:indexed, 252}, bg: {:indexed, 234}},
    user_surface: %Style{fg: {:indexed, 252}, bg: {:indexed, 235}},
    selection_surface: %Style{fg: {:indexed, 252}, bg: {:indexed, 60}},
    error_surface: %Style{fg: {:indexed, 252}, bg: {:indexed, 52}},
    diff_add: %Style{fg: {:indexed, 114}},
    diff_add_bg: %Style{bg: {:indexed, 22}},
    diff_add_gutter: %Style{fg: {:indexed, 243}},
    diff_add_inline: %Style{fg: {:indexed, 151}, bg: {:indexed, 28}},
    diff_del: %Style{fg: {:indexed, 174}},
    diff_del_bg: %Style{bg: {:indexed, 52}},
    diff_del_gutter: %Style{fg: {:indexed, 243}},
    diff_del_inline: %Style{fg: {:indexed, 217}, bg: {:indexed, 88}},
    diff_context: %Style{fg: {:indexed, 245}}
  }

  @light_styles %{
    text: %Style{},
    muted: %Style{fg: {:indexed, 240}},
    subtle: %Style{fg: {:indexed, 243}},
    accent: %Style{fg: {:indexed, 25}, modifiers: [:bold]},
    accent_soft: %Style{fg: {:indexed, 25}},
    success: %Style{fg: {:indexed, 28}},
    warning: %Style{fg: {:indexed, 94}},
    error: %Style{fg: {:indexed, 124}},
    surface: %Style{fg: {:indexed, 235}, bg: {:indexed, 255}},
    surface_raised: %Style{fg: {:indexed, 235}, bg: {:indexed, 254}},
    code_surface: %Style{fg: {:indexed, 235}, bg: {:indexed, 255}},
    user_surface: %Style{fg: {:indexed, 235}, bg: {:indexed, 255}},
    selection_surface: %Style{fg: {:indexed, 235}, bg: {:indexed, 153}},
    error_surface: %Style{fg: {:indexed, 235}, bg: {:indexed, 224}},
    diff_add: %Style{fg: {:indexed, 28}},
    diff_add_bg: %Style{bg: {:indexed, 194}},
    diff_add_gutter: %Style{fg: {:indexed, 236}, bg: {:indexed, 157}},
    diff_add_inline: %Style{fg: {:indexed, 22}, bg: {:indexed, 157}},
    diff_del: %Style{fg: {:indexed, 124}},
    diff_del_bg: %Style{bg: {:indexed, 224}},
    diff_del_gutter: %Style{fg: {:indexed, 236}, bg: {:indexed, 217}},
    diff_del_inline: %Style{fg: {:indexed, 88}, bg: {:indexed, 217}},
    diff_context: %Style{fg: {:indexed, 240}}
  }

  @type mode :: :light | :dark

  @doc "Returns the palette selected by TACKLE_THEME, the terminal's reported background, and COLORFGBG."
  @spec mode() :: mode()
  def mode,
    do: resolve(System.get_env("TACKLE_THEME"), System.get_env("COLORFGBG"), reported())

  @doc """
  Resolves the palette mode from an explicit override, a terminal-reported
  background, and the `COLORFGBG` heuristic, in that order.
  """
  @spec resolve(String.t() | nil, String.t() | nil, mode() | nil) :: mode()
  def resolve(theme, colorfgbg, reported \\ nil)

  def resolve("light", _colorfgbg, _reported), do: :light
  def resolve("dark", _colorfgbg, _reported), do: :dark
  def resolve(_auto, _colorfgbg, reported) when reported in [:light, :dark], do: reported

  def resolve(_auto, colorfgbg, nil) when is_binary(colorfgbg) do
    case colorfgbg |> String.split(";") |> List.last() |> Integer.parse() do
      {index, ""} when index in 0..255 ->
        if light_background?(index), do: :light, else: :dark

      _ ->
        :dark
    end
  end

  def resolve(_auto, _colorfgbg, nil), do: :dark

  @doc """
  Remembers a terminal-reported background mode for the lifetime of the VM.

  `Tackle.CLI.TUI.TerminalBackground` calls this once, before the first
  frame renders; the terminal's background does not change while the shell
  runs.
  """
  @spec remember_background(mode()) :: :ok
  def remember_background(mode) when mode in [:light, :dark] do
    :persistent_term.put({__MODULE__, :background}, mode)
    :ok
  end

  defp reported, do: :persistent_term.get({__MODULE__, :background}, nil)

  @doc """
  Returns whether an 8-bit RGB background reads as light.

  Weighted luminance, shared by the indexed-color heuristic below and the
  terminal's OSC 11 reply, so both detection paths classify one color the
  same way.
  """
  @spec light_rgb?({non_neg_integer(), non_neg_integer(), non_neg_integer()}) :: boolean()
  def light_rgb?({red, green, blue}), do: 299 * red + 587 * green + 114 * blue > 153_000

  # Standard ANSI backgrounds are themeable, so this is only a heuristic.
  # For the fixed 256-color cube and grayscale ramp, use weighted brightness.
  defp light_background?(index) when index < 16, do: index in [7, 15]

  defp light_background?(index) when index >= 232 do
    gray = 8 + 10 * (index - 232)
    light_rgb?({gray, gray, gray})
  end

  defp light_background?(index) do
    cube = index - 16
    levels = {0, 95, 135, 175, 215, 255}

    light_rgb?({
      elem(levels, div(cube, 36)),
      elem(levels, div(rem(cube, 36), 6)),
      elem(levels, rem(cube, 6))
    })
  end

  @doc "Returns the semantic style for `tone`, optionally from an explicit palette."
  @spec style(tone() | atom(), mode()) :: Style.t()
  def style(tone, mode \\ mode())
  def style(tone, :light), do: Map.get(@light_styles, tone, %Style{})
  def style(tone, :dark), do: Map.get(@dark_styles, tone, %Style{})

  @doc """
  Returns the Markdown element styles for the native prose renderer.

  The keys are the wire contract of the Rust `MarkdownWire` map: the native
  conversation widget turns each entry into a `tui_markdown` stylesheet, so
  assistant prose follows the selected palette instead of the renderer's
  own defaults (cyan heading bands, white-on-black code, green quotes).
  Both sides must list exactly these keys.

  The look stays minimal: headings are bold accent text without their `#`
  markers, inline code sits on the same surface as fenced code, quotes read
  like thinking text, and only meaning-carrying elements (alerts, links) get
  color. Table borders and metadata recede to `:subtle`.
  """
  @spec markdown_styles() :: %{atom() => Style.t()}
  def markdown_styles do
    %{
      heading: bold(style(:accent_soft)),
      code: style(:code_surface),
      link: underlined(style(:accent_soft)),
      blockquote: italic(style(:muted)),
      meta: style(:subtle),
      math: italic(style(:accent_soft)),
      alert_note: style(:accent_soft),
      alert_tip: style(:success),
      alert_important: bold(style(:accent_soft)),
      alert_warning: style(:warning),
      alert_caution: style(:error),
      table_header: bold(style(:text)),
      table_cell: style(:text),
      table_border: style(:subtle)
    }
  end

  @typedoc "The title meaning an overlay panel carries."
  @type panel_tone :: :accent | :warning | :error

  @doc """
  Builds the rounded panel chrome shared by every overlay.

  Borders stay neutral. The tone names the title's meaning: `:accent` for
  ordinary overlays, `:warning` for confirmations, `:error` for failures.
  Ordinary titles are bold muted text, so color stays reserved for meaning.
  """
  @spec panel_block(String.t(), panel_tone()) :: Block.t()
  def panel_block(title, tone) do
    %Block{
      title: title,
      borders: [:all],
      border_type: :rounded,
      border_style: style(:subtle),
      title_style: panel_title_style(tone)
    }
  end

  defp panel_title_style(:accent), do: bold(style(:muted))
  defp panel_title_style(:warning), do: bold(style(:warning))
  defp panel_title_style(:error), do: bold(style(:error))

  @doc "Adds bold to a style without dropping its color or background."
  @spec bold(Style.t()) :: Style.t()
  def bold(%Style{} = style), do: %{style | modifiers: Enum.uniq([:bold | style.modifiers])}

  @doc "Adds italic to a style without dropping its color or background."
  @spec italic(Style.t()) :: Style.t()
  def italic(%Style{} = style), do: %{style | modifiers: Enum.uniq([:italic | style.modifiers])}

  @doc "Adds an underline to a style without dropping its color or background."
  @spec underlined(Style.t()) :: Style.t()
  def underlined(%Style{} = style),
    do: %{style | modifiers: Enum.uniq([:underlined | style.modifiers])}

  @doc """
  Layers `override` over `base`, keeping base fields the override leaves unset.

  This is how a surface background survives when a row only wants to change the
  foreground: `merge(style(:surface), style(:muted))`.
  """
  @spec merge(Style.t(), Style.t()) :: Style.t()
  def merge(%Style{} = base, %Style{} = override) do
    %Style{
      fg: override.fg || base.fg,
      bg: override.bg || base.bg,
      underline_color: override.underline_color || base.underline_color,
      modifiers: Enum.uniq(base.modifiers ++ override.modifiers)
    }
  end
end

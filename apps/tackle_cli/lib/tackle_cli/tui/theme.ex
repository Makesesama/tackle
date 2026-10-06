defmodule Tackle.CLI.TUI.Theme do
  @moduledoc """
  Semantic styles for the transcript-first shell.

  Renderers never hard-code terminal colors: they ask for a role such as
  `:muted` or `:surface` and get a `%ExRatatui.Style{}` back. The palette uses
  indexed colors so it is stable on true-color and 256-color terminals and
  degrades to the nearest named color elsewhere.

  `TACKLE_THEME=light` or `dark` selects a palette explicitly. Otherwise the
  final background index in `COLORFGBG` is used when available, falling back to
  dark. This is a heuristic, not a terminal query. Surface roles always pair
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
    surface: %Style{fg: {:indexed, 235}, bg: {:indexed, 254}},
    surface_raised: %Style{fg: {:indexed, 235}, bg: {:indexed, 252}},
    code_surface: %Style{fg: {:indexed, 235}, bg: {:indexed, 254}},
    user_surface: %Style{fg: {:indexed, 235}, bg: {:indexed, 254}},
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

  @doc "Returns the palette selected by TACKLE_THEME and COLORFGBG."
  @spec mode() :: mode()
  def mode, do: resolve(System.get_env("TACKLE_THEME"), System.get_env("COLORFGBG"))

  @doc "Resolves an explicit light/dark override, or the final COLORFGBG palette index."
  @spec resolve(String.t() | nil, String.t() | nil) :: mode()
  def resolve("light", _colorfgbg), do: :light
  def resolve("dark", _colorfgbg), do: :dark

  def resolve(_auto, colorfgbg) when is_binary(colorfgbg) do
    case colorfgbg |> String.split(";") |> List.last() |> Integer.parse() do
      {index, ""} when index in 0..255 ->
        if light_background?(index), do: :light, else: :dark

      _ ->
        :dark
    end
  end

  def resolve(_auto, _colorfgbg), do: :dark

  # Standard ANSI backgrounds are themeable, so this is only a heuristic.
  # For the fixed 256-color cube and grayscale ramp, use weighted brightness.
  defp light_background?(index) when index < 16, do: index in [7, 15]
  defp light_background?(index) when index >= 232, do: 8 + 10 * (index - 232) > 153

  defp light_background?(index) do
    cube = index - 16
    levels = {0, 95, 135, 175, 215, 255}
    r = elem(levels, div(cube, 36))
    g = elem(levels, div(rem(cube, 36), 6))
    b = elem(levels, rem(cube, 6))
    299 * r + 587 * g + 114 * b > 153_000
  end

  @doc "Returns the semantic style for `tone`, optionally from an explicit palette."
  @spec style(tone() | atom(), mode()) :: Style.t()
  def style(tone, mode \\ mode())
  def style(tone, :light), do: Map.get(@light_styles, tone, %Style{})
  def style(tone, :dark), do: Map.get(@dark_styles, tone, %Style{})

  @doc """
  Builds the rounded panel chrome shared by every overlay.

  Borders stay neutral. The existing color argument supplies a semantic title
  accent, so confirmations retain their warning without a bright perimeter.
  """
  @spec panel_block(String.t(), atom()) :: Block.t()
  def panel_block(title, color) do
    %Block{
      title: title,
      borders: [:all],
      border_type: :rounded,
      border_style: style(:subtle),
      title_style: panel_title_style(color)
    }
  end

  defp panel_title_style(:cyan), do: style(:accent_soft)
  defp panel_title_style(:yellow), do: style(:warning)
  defp panel_title_style(:red), do: style(:error)
  defp panel_title_style(color), do: %Style{fg: color}

  @doc "Adds bold to a style without dropping its color or background."
  @spec bold(Style.t()) :: Style.t()
  def bold(%Style{} = style), do: %{style | modifiers: Enum.uniq([:bold | style.modifiers])}

  @doc "Adds italic to a style without dropping its color or background."
  @spec italic(Style.t()) :: Style.t()
  def italic(%Style{} = style), do: %{style | modifiers: Enum.uniq([:italic | style.modifiers])}

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

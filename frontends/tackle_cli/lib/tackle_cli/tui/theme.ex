defmodule Tackle.CLI.TUI.Theme do
  @moduledoc """
  Semantic styles for the transcript-first shell.

  Renderers never hard-code terminal colors: they ask for a role such as
  `:muted` or `:surface` and get a `%ExRatatui.Style{}` back. The palette uses
  indexed colors so it is stable on true-color and 256-color terminals and
  degrades to the nearest named color elsewhere.

  Two kinds of role exist:

    * foreground tones (`:text`, `:muted`, `:subtle`, `:accent`, `:success`,
      `:warning`, `:error`) that carry meaning on their own, and
    * surface roles (`:surface`, `:surface_raised`, `:user_surface`) that paint
      a full-width band behind a block of rows.

  Surfaces are deliberately subtle: they sit a few steps off the terminal
  background so a card reads as a block without competing with the prose.
  `:diff_add` and `:diff_del` are soft foreground accents for counts and `+`/`-`
  markers. Diff rows leave the terminal background untouched; only changed
  tokens use the restrained `:diff_add_inline` and `:diff_del_inline` tints.

  A desaturated blue accent marks activity and selection. Overlay borders and
  the composer divider stay neutral; warning and error colors carry meaning
  rather than decorating the shell.
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
          | :user_surface
          | :error_surface
          | :selection_surface
          | :diff_add
          | :diff_add_inline
          | :diff_del
          | :diff_del_inline
          | :diff_context

  @styles %{
    text: %Style{},
    muted: %Style{fg: {:indexed, 246}},
    subtle: %Style{fg: {:indexed, 243}},
    accent: %Style{fg: {:indexed, 110}, modifiers: [:bold]},
    accent_soft: %Style{fg: {:indexed, 110}},
    success: %Style{fg: {:indexed, 114}},
    warning: %Style{fg: {:indexed, 179}},
    error: %Style{fg: {:indexed, 174}},
    surface: %Style{bg: {:indexed, 235}},
    surface_raised: %Style{bg: {:indexed, 237}},
    user_surface: %Style{bg: {:indexed, 235}},
    selection_surface: %Style{bg: {:indexed, 60}},
    error_surface: %Style{bg: {:indexed, 52}},
    diff_add: %Style{fg: {:indexed, 114}},
    diff_add_inline: %Style{fg: {:indexed, 151}, bg: {:indexed, 22}},
    diff_del: %Style{fg: {:indexed, 174}},
    diff_del_inline: %Style{fg: {:indexed, 217}, bg: {:indexed, 52}},
    diff_context: %Style{fg: {:indexed, 245}}
  }

  @doc "Returns the semantic style for `tone`."
  @spec style(tone() | atom()) :: Style.t()
  def style(tone), do: Map.get(@styles, tone, %Style{})

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

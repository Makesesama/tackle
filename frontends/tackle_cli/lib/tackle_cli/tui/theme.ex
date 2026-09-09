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
  `:diff_add` and `:diff_del` pair a foreground with a tinted background so the
  `+`/`-` markers survive even where the background is not painted.
  """

  alias ExRatatui.Style

  @type tone ::
          :text
          | :muted
          | :subtle
          | :accent
          | :success
          | :warning
          | :error
          | :surface
          | :surface_raised
          | :user_surface
          | :error_surface
          | :diff_add
          | :diff_del
          | :diff_context

  @styles %{
    text: %Style{},
    muted: %Style{fg: {:indexed, 245}},
    subtle: %Style{fg: {:indexed, 240}},
    accent: %Style{fg: :cyan, modifiers: [:bold]},
    accent_soft: %Style{fg: :cyan},
    success: %Style{fg: :green},
    warning: %Style{fg: :yellow},
    error: %Style{fg: :red},
    surface: %Style{bg: {:indexed, 235}},
    surface_raised: %Style{bg: {:indexed, 237}},
    user_surface: %Style{bg: {:indexed, 236}},
    error_surface: %Style{bg: {:indexed, 52}},
    diff_add: %Style{fg: :green, bg: {:indexed, 22}},
    diff_del: %Style{fg: :red, bg: {:indexed, 52}},
    diff_context: %Style{fg: {:indexed, 245}, bg: {:indexed, 235}}
  }

  @doc "Returns the semantic style for `tone`."
  @spec style(tone() | atom()) :: Style.t()
  def style(tone), do: Map.get(@styles, tone, %Style{})

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

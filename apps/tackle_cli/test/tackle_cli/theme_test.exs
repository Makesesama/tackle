defmodule Tackle.CLI.TUI.ThemeTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.Theme

  test "explicit palettes override detection" do
    assert Theme.resolve("light", "15;0") == :light
    assert Theme.resolve("dark", "0;15") == :dark
  end

  test "a reported background outranks COLORFGBG but not the override" do
    assert Theme.resolve(nil, "15;0", :light) == :light
    assert Theme.resolve(nil, "0;15", :dark) == :dark
    assert Theme.resolve(nil, "0;255", :light) == :light
    assert Theme.resolve("dark", "0;15", :light) == :dark
    assert Theme.resolve("light", "15;0", :dark) == :light
    assert Theme.resolve("auto", nil, :dark) == :dark
  end

  test "auto uses the final COLORFGBG background, including 256-color indices" do
    for override <- [nil, "auto", "unknown"] do
      for value <- ["0;15", "0;default;7", "0;255", "0;231"] do
        assert Theme.resolve(override, value) == :light
      end

      for value <- [
            nil,
            "",
            "garbage",
            "0;",
            "0;256",
            "0;-1",
            "0;15junk",
            "15;0",
            "15;8",
            "15;232",
            "15;16",
            "15;21"
          ] do
        assert Theme.resolve(override, value) == :dark
      end
    end
  end

  test "every painted surface supplies foreground and background in both palettes" do
    for mode <- [:light, :dark],
        tone <- [
          :surface,
          :surface_raised,
          :user_surface,
          :code_surface,
          :selection_surface,
          :error_surface,
          :diff_add_inline,
          :diff_del_inline
        ] do
      style = Theme.style(tone, mode)
      assert style.fg != nil
      assert style.bg != nil
      refute style.fg == style.bg
    end

    # Diff fills are background-only layers; content keeps its own foreground.
    for mode <- [:light, :dark], tone <- [:diff_add_bg, :diff_del_bg] do
      style = Theme.style(tone, mode)
      assert style.fg == nil
      assert style.bg != nil
    end

    # Light gutters are opaque and more saturated than the fill so numbers stay
    # readable on the pastel; dark gutters are a dim foreground over the fill.
    for tone <- [:diff_add_gutter, :diff_del_gutter] do
      light = Theme.style(tone, :light)
      assert light.fg != nil and light.bg != nil
      dark = Theme.style(tone, :dark)
      assert dark.fg != nil and dark.bg == nil
    end

    # Intraline emphasis stays one step more saturated than the line fill, so
    # changed tokens remain visible on the painted background.
    for mode <- [:light, :dark] do
      refute Theme.style(:diff_add_inline, mode).bg == Theme.style(:diff_add_bg, mode).bg
      refute Theme.style(:diff_del_inline, mode).bg == Theme.style(:diff_del_bg, mode).bg
    end

    assert Theme.style(:text, :light) == %ExRatatui.Style{}
    assert Theme.style(:unknown, :light) == %ExRatatui.Style{}
  end

  test "overlays share a neutral border while titles carry the tone's meaning" do
    menu = Theme.panel_block(" Model ", :accent)
    confirm = Theme.panel_block(" Confirm quit ", :warning)

    assert menu.borders == [:all]
    assert menu.border_type == :rounded
    assert menu.border_style == Theme.style(:subtle)
    assert confirm.border_style == menu.border_style
    assert menu.title_style == Theme.bold(Theme.style(:muted))
    assert confirm.title_style == Theme.bold(Theme.style(:warning))
    refute confirm.title_style == menu.title_style
  end

  test "light_rgb?/1 classifies the shared luminance boundary" do
    assert Theme.light_rgb?({255, 255, 255})
    assert Theme.light_rgb?({250, 246, 227})
    refute Theme.light_rgb?({128, 128, 128})
    refute Theme.light_rgb?({30, 30, 46})
  end
end

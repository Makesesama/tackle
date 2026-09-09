# Markdown Conversation History — Implementation Status

_Last updated: 2026-09-09_

## Goal

The Tackle CLI conversation history renders assistant messages as Markdown while
preserving streaming updates, terminal resize behavior, row-based scrolling,
follow-to-latest behavior, mouse hit detection, and bounded rendering for long
histories. Conversation state and message presentation are separated from the
TUI lifecycle.

## Implemented

The CLI now has two focused presentation modules:

- `Tackle.CLI.TUI.Conversation` owns the conversation panel dimensions, section
  cache, row heights, viewport slicing, scrolling, follow-tail policy, title,
  and mouse hit detection.
- `Tackle.CLI.TUI.MessageView` owns typed conversation entries and conversion to
  primitive ExRatatui widgets. User, thinking, tool, error, and welcome entries
  remain Paragraph widgets. Assistant entries use
  `%ExRatatui.Widgets.Markdown{}` with the provider's Markdown source preserved
  unchanged.

Assistant height is calculated with:

```elixir
ExRatatui.Widgets.Markdown.measure_height(content, available_width)
```

The measured height is cached with each rendered item and recalculated whenever
streaming content changes or the terminal width changes. The measured width is
the conversation panel's inner width, matching the width used by the Markdown
widget at render time.

A long assistant response is not split into Markdown source fragments. When its
measured height exceeds the 64-row WidgetList safety chunk, the view creates
bounded Markdown windows that all retain the complete source and set the
widget's vertical `scroll` offset. This preserves fenced-code, list, and other
Markdown semantics while allowing `Conversation` to pass only the items that
intersect the viewport to `WidgetList`. Row scrolling and partial-item clipping
therefore continue to work without an unbounded WidgetList item. The public
ExRatatui API has no pre-rendered Markdown-line primitive, so each visible
window still lets the native renderer parse the complete source; source
splitting would be less correct. ExRatatui and Ratatui encode Paragraph scroll
offsets as unsigned 16-bit values. If a pathological response exceeds 65,536
rendered rows, the CLI falls back to bounded plain-text source windows rather
than constructing an invalid Markdown widget and crashing.

Streaming deltas rebuild only their section (`:thinking`, `:response`, or
`:tools`). Settled messages and all sections are rebuilt when a turn completes,
the session is reconfigured, or the terminal is resized. Existing row scrolling,
mouse-wheel hit testing, and follow-to-latest behavior remain in place.

Focused CLI tests cover:

- actual Markdown widgets and role styles;
- exact width-aware assistant heights;
- streaming Markdown with an incomplete fenced code block;
- resize remeasurement;
- row scrolling, follow-tail behavior, mouse scrolling, and long histories;
- preserving complete Markdown source across bounded long-response windows;
- safe fallback beyond the native Markdown scroll-offset range;
- existing user, thinking, tool, error, and lifecycle behavior.

## ExRatatui integration

The frontend uses the approved local fork rather than the published Hex package:

```elixir
{:ex_ratatui, path: "../../repos/ex_ratatui"}
```

The fork is expected at `repos/ex_ratatui` at commit `410c2e7`. It still declares
version `0.13.1`; therefore version resolution alone would make
`RustlerPrecompiled` load the published 0.13.1 NIF, which does not export
`markdown_measure_height/2`. `frontends/tackle_cli/config/config.exs` forces a
source build:

```elixir
config :rustler_precompiled, :force_build, ex_ratatui: true
```

The CLI also declares direct `{:rustler, ">= 0.0.0"}` because ExRatatui's
Rustler dependency is optional and is not fetched transitively for a source
build. A Rust/Cargo toolchain is consequently required for CLI compilation.
The nested fork is not modified by this Tackle change.

This local path is a temporary development integration. Once the measurement
API is released in a portable ExRatatui package, the CLI can return to that
released dependency and remove the force-build workaround.

## Validation

The focused TUI test suite passes with the local fork source-built. The full
CLI checks should be run from `frontends/tackle_cli`:

```sh
mix deps.get
mix format 'lib/tackle_cli/tui.ex' 'lib/tackle_cli/tui/**/*.ex' 'test/tackle_cli/tui_test.exs' 'mix.exs' 'config/config.exs'
mix compile --warnings-as-errors
mix test
mix format --check-formatted
```

The repository-level final check is:

```sh
git diff --check
```

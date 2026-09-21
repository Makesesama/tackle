# Markdown Conversation History — Implementation Status

_Last updated: 2026-09-21_

## Goal

The Tackle CLI conversation history renders assistant messages as Markdown while
preserving streaming updates, terminal resize behavior, row-based scrolling,
follow-to-latest behavior, mouse hit detection, and bounded rendering for long
histories.

## Implemented

The conversation path is split between Elixir projection and a Tackle-owned
native widget:

- `Tackle.CLI.TUI.Conversation` owns panel dimensions, section caches, row
  heights, scrolling, follow-tail policy, and mouse hit detection.
- `Tackle.CLI.TUI.MessageView` projects messages into typed entries and renders
  non-message entries as primitive ExRatatui widgets.
- `Tackle.CLI.Widgets.Conversation` turns user and assistant entries into
  immutable native history cells and renders only visible viewport rows.
- `native/tackle/src/widgets/conversation.rs` parses assistant Markdown,
  measures wrapped lines with Ratatui, caches width-dependent layout, clips the
  viewport, and paints selection styles.

Assistant source is parsed with `tui-markdown` and measured with Ratatui's
`Paragraph::line_count`. The native cell returns its measured height to Elixir
and is rebuilt when streaming content or the terminal width changes. Settled
cells remain cached while the live tail updates.

Transcript scrolling is not limited by Ratatui's `u16` paragraph scroll field.
The native widget stores transcript-wide offsets as `usize`, renders clipped
logical-line windows, and grapheme-wraps exceptionally tall individual lines.
The complete Markdown source remains available for copy and inspection.

Focused Elixir integration tests cover Markdown rendering, incomplete fenced
code blocks during streaming, resize remeasurement, long histories, viewport
clipping, selection, and source preservation. Rust unit tests compare native
measurement and clipped windows directly against Ratatui and cover offsets
beyond the `u16` range.

## ExRatatui integration

The frontend uses the released Hex package:

```elixir
{:ex_ratatui, "~> 0.15.0"}
```

Normal development uses ExRatatui's published precompiled NIF. Tackle's native
conversation and input widgets remain a separate Rustler crate with no shared
resources or ABI, so the CLI still declares `:rustler` directly and requires a
Rust/Cargo toolchain for that crate.

For Linux Burrito releases, `TARGET_ABI=musl` selects ExRatatui's precompiled
musl artifact while Tackle's NIF is compiled for the same target. The Nix
package builds both NIFs reproducibly from their locked sources.

## Validation

Run the CLI checks from `apps/tackle_cli`:

```sh
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted
```

The repository-level final check is:

```sh
git diff --check
```

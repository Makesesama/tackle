# Markdown Conversation History — Implementation Status

_Last updated: 2026-09-08_

## Goal

Enhance the Tackle CLI conversation history so assistant messages render as Markdown while preserving streaming updates, terminal resize behavior, row-based scrolling, and follow-to-latest behavior. As part of this work, split the conversation/message responsibilities out of the large `frontends/tackle_cli/lib/tackle_cli/tui.ex` module.

## What I am doing

The implementation is being approached in two parts:

1. Add an exact, width-aware Markdown height API to `ex_ratatui`.
2. Refactor Tackle's TUI around typed conversation entries and render assistant entries with `ExRatatui.Widgets.Markdown`.

Exact height measurement is necessary because `ExRatatui.Widgets.WidgetList` requires a row height for every child. Estimating from source lines is not correct once Markdown wrapping, code blocks, lists, Unicode width, and terminal resizing are involved.

## Current state

### Completed: research and architecture analysis

I inspected:

- Pi's Markdown renderer and assistant-message pipeline under `repos/pi/packages/tui` and `repos/pi/packages/coding-agent`.
- ExRatatui's Markdown renderer and WidgetList implementation under `repos/ex_ratatui`.
- Tackle's current conversation rendering, section cache, scrolling, resize handling, and tests in `frontends/tackle_cli/lib/tackle_cli/tui.ex` and `frontends/tackle_cli/test/tackle_cli/tui_test.exs`.

The intended Tackle structure is:

- `Tackle.CLI.TUI` — application lifecycle, event routing, and top-level layout.
- `Tackle.CLI.TUI.Conversation` — conversation cache, dimensions, visible-item slicing, scrolling, and follow-tail policy.
- `Tackle.CLI.TUI.MessageView` — conversion of user, assistant, thinking, tool, and error entries into ExRatatui widgets.

Assistant text will be Markdown. User, thinking, tool, and error entries will remain separate widgets initially so provider/tool lifecycle information is not embedded into generated Markdown.

### In progress: ExRatatui Markdown measurement

The separate nested repository at `repos/ex_ratatui` currently has local changes in seven files:

- `CHANGELOG.md`
- `lib/ex_ratatui/native.ex`
- `lib/ex_ratatui/widgets/markdown.ex`
- `native/ex_ratatui/Cargo.toml`
- `native/ex_ratatui/src/widgets/markdown.rs`
- `test/ex_ratatui/widgets/markdown_test.exs`
- `usage-rules.md`

The new API is:

```elixir
ExRatatui.Widgets.Markdown.measure_height(content, width)
```

It uses the same `tui-markdown` parser and Ratatui `Paragraph` wrapping path as rendering. Ratatui's `unstable-rendered-line-info` feature is enabled so native code can call `Paragraph.line_count/1` rather than duplicating or approximating Ratatui's wrapping rules.

The API currently includes:

- validation for Markdown content and terminal width;
- public documentation and examples;
- Elixir tests for wrapping, empty content, and invalid arguments;
- Rust tests for Markdown layout and word wrapping;
- changelog and usage-rule documentation.

### Validation completed

The focused native Rust tests pass:

```text
cargo test widgets::markdown

11 passed; 0 failed; 326 filtered out
```

The test command was run with a Nix-provided Rust toolchain because `cargo` is not part of the project's currently inherited shell PATH.

### Not implemented yet

No tracked Tackle source file has been changed yet. In particular, the following remains:

- move conversation state/layout logic out of `tui.ex`;
- introduce typed message view entries;
- render assistant entries with `%ExRatatui.Widgets.Markdown{}`;
- use exact measured Markdown heights;
- preserve bounded visible-item rendering for long histories;
- update the Tackle CLI tests for Markdown, streaming, resize, scrolling, code fences, and follow-tail behavior;
- run the full checks for both affected projects.

## Dependency/integration issue being handled

Tackle currently depends on the published Hex package:

```elixir
{:ex_ratatui, "~> 0.13"}
```

and locks version `0.13.1`. The edited `repos/ex_ratatui` directory is a separate, untracked Git repository used for development/research. Tackle must not be left with a relative path dependency on that directory because a normal checkout and CI environment would not contain it.

Therefore I am not changing Tackle to depend permanently on `../../repos/ex_ratatui`. The exact integration needs to remain portable: either the backward-compatible ExRatatui API must be released within the accepted `0.13.x` range, or Tackle must temporarily use a carefully isolated compatibility path until that release exists. I am avoiding a fake version bump or an unpublishable Git reference.

## Working-tree safety

The main Tackle repository had no tracked modifications when implementation began. Existing untracked files and directories have been preserved. The only source modifications so far are inside the separate `repos/ex_ratatui` Git repository.

## Next steps

1. Finish ExRatatui source-build and Elixir-side validation.
2. Extract `Conversation` and `MessageView` from Tackle's `tui.ex` without changing behavior.
3. Add Markdown assistant widgets and exact height caching keyed by content and width.
4. Preserve streaming section-only refreshes and follow-tail behavior.
5. Add regression tests for Markdown syntax, incomplete fenced code, resize remeasurement, scrolling, and long responses.
6. Run formatting, warnings-as-errors compilation, tests, and diff checks for both repositories.

# Tackle CLI

Terminal frontend and default product entrypoint for the Tackle developer
harness.

This is a separate Mix project so CLI dependencies and presentation concerns stay
out of the root harness and `packages/tackle_lib`. The shipped CLI distribution
bundles the first-party `plugins/tackle_codex` and `plugins/tackle_deepseek`
adapters, configures them as available harness adapters, and then talks to the
root `:tackle` application for
configuration, credential storage, scoped runtime ownership, and turn execution.
The CLI starts one root scope, addresses the root agent through a
`Tackle.Runtime.AgentRef`, and stops the complete scope on exit; it never stores
or checks a runtime PID.

The CLI may select a canonical model reference with `--model` and a reasoning
level with `--thinking`, but it does not load or select adapter modules directly.
Adapter availability is a harness and distribution concern.

## Usage during development

From the repository root, fetch the frontend dependencies once and then use the
root delegation task:

```sh
(cd frontends/tackle_cli && mix deps.get)
mix tackle --help
mix tackle models
mix tackle auth status
mix tackle auth status deepseek
mix tackle auth login openai-codex
mix tackle auth login deepseek
mix tackle auth usage deepseek
mix tackle auth logout deepseek
mix tackle run --model deepseek/deepseek-chat "Inspect this project"
mix tackle run --thinking high "Inspect this project"
mix tackle run --resume SESSION_ID
mix tackle run --resume
mix tackle run --resume -- "Carry on from here"
mix tackle run --resume SESSION_ID --abandon
```

Resuming automatically runs controlled repair when the journal was not closed
cleanly. Tackle preserves the original journal under the session's `recovery/`
directory and validates recovered history before use. `--abandon` remains an
explicit, separate decision for a turn interrupted by the crash.

`--resume` without a session id continues the most recently updated durable
session. Quitting the shell prints the command that reopens the session it was
last attached to, so a session started, or switched to, inside the shell is also
recoverable. A session id directly after `--resume` always wins, so a one-shot
prompt for a valueless `--resume` follows `--` (or comes before the flag).

Provider login, logout, status, and usage are adapter-driven: the CLI resolves
the adapter by its `adapter_id` and delegates, so any configured
`Tackle.Lib.LLM` plugin works without CLI changes. `auth status` without a
provider lists every configured provider. DeepSeek login prompts for a key
through the adapter and stores it under the `deepseek` credential namespace;
`auth usage deepseek` reports the account balance, and `auth usage` without a
provider reports it for every provider that supports it. The credential file is
plaintext JSON protected by user-only filesystem permissions; alternatively, set
`DEEPSEEK_API_KEY`. When the terminal does not support hidden input, the command
falls back to a visible prompt.

The same `mix tackle` commands continue to work from this directory. Run
`mix tackle` without a prompt to open the supervised `ExRatatui.App` TUI.
The shell is transcript-first and fullscreen: a compact header, a border-light
transcript that owns the flexible middle of the screen, an optional reading row,
an optional status/metrics row, a growing multiline composer, and a responsive
hint row. Empty optional rows are not reserved when the terminal is short.

## Keys (experimental)

| Key | Action |
| --- | --- |
| Enter | Send the draft when idle. While a turn is active the draft is kept but **not queued**. |
| Shift+Enter, Ctrl+Enter, Ctrl+J | Insert a newline. Ctrl+J is the reliable fallback because many terminals cannot distinguish Shift+Enter. |
| Esc | Close the open overlay first, then request cancellation of the active turn. Esc never exits while idle. |
| Ctrl+C | Quit. Confirms first when an unsent draft or an active turn would be lost; quits immediately when idle with an empty draft. |
| Alt+N | Start a new session. Confirms first with a Y/N prompt; on confirm the current root scope stops (stopping an active turn with it) and a fresh session and scope start without restarting the shell. Durable history is not deleted—resume it later with `--resume`. |
| F1 | Searchable command/help palette. Type to filter, ↑/↓ to select, Enter to run, Esc to close. |
| F2 | Model and thinking selector (idle only). ↑/↓ switches field, ←/→ cycles, Enter applies, Esc cancels. A reconfigure failure preserves the conversation and the draft. |
| F3 | Source copy overlay. ↑/↓ selects, Y/Enter copies the full retained source of the entry, O opens the output inspector, A copies the full transcript, Esc closes. |
| F4 | Browse transcript entries with ↑/↓. Enter opens the selected entry (including compaction summaries) in the scrollable inspector; Y copies its source; Esc returns to the composer. |
| F5, `/tree` | Open the conversation-tree picker (idle only). Search, ↑/↓, Enter to move; Esc closes. |
| Ctrl+F | Transcript search over full retained message and tool source. Type a query, Enter/↓ next match, ↑ previous, Esc closes. The query is never sent to the agent. |
| Ctrl+K | Compact context manually while idle. The draft is retained. Manual compaction cannot currently be cancelled. |
| Ctrl+T | Reveal or collapse supplied reasoning. |
| Page Up/Page Down, mouse wheel | Scroll the transcript. Ctrl+Home jumps to the oldest row; Ctrl+End returns to the newest row and resumes following. |

## Composer behavior

The composer is Tackle's custom Rust `Input` widget in `native/tackle`, inspired
by the separation between Codex's textarea and higher-level composer. It grows
with the draft's **wrapped screen rows** up to eight visible rows, then scrolls
vertically to keep the caret visible. Wrapping uses grapheme boundaries (not
word boundaries), preserves source whitespace, and reserves a visible insertion
cell at the end of a full row. Resizing remeasures the draft and transcript.

Left/Right and Backspace/Delete operate on complete graphemes, including
combining marks and emoji. Up/Down move by visual row and retain the preferred
column. Home/End and Ctrl+A/E move to logical line boundaries; Ctrl+W deletes
the preceding whitespace-delimited word. The caret is hidden while browsing or
using an overlay. Tabs paint as spaces and other control characters as visible
replacements without changing the submitted source.

Bracketed paste lands as one edit and never submits. CRLF is normalized to `\n`;
lone CR is dropped before the edit. Ctrl+U undoes and Ctrl+R redoes a full
multiline paste. Undo and redo each retain at most 100 snapshots / 8 MiB; a
programmatic draft replacement resets both histories. Unknown modified chords
(for example Alt+G) are ignored by the
native widget. Key releases are ignored; key repeats apply to text and
navigation but not to submit, quit, or overlay shortcuts.

While a turn is active the composer is labeled "Draft · next turn (not queued)"
and Enter does not send. There is no queue, so the draft is explicitly reserved
for the next turn instead of being delivered to the running one. A failed
submit, failed reconfiguration, or rejected operation keeps the exact draft in
the composer.

## Transcript behavior

The conversation is Tackle's custom Rust `Conversation` widget in
`native/tackle`, inspired by Codex's history cells and live transcript tail.
Elixir retains ordered entries, copy/search source, tool preview formatting,
and reading anchors. Immutable native cells own Markdown parsing, measured
layout, viewport clipping, and selection paint. Unchanged cells are reused on
stream updates and selection changes; resizing replaces width-dependent cells.
Old scene snapshots remain valid after updates. ExRatatui still owns the
terminal and receives only the viewport's owned styled rows—no NIF resources
or pointers are shared between native libraries.

The conversation renders assistant responses as Markdown, including while a
response is streaming. Tool calls and matching results share one card, identified
by call ID, with the command or path as its heading rather than a JSON argument
dump. Successful tool output is subdued; failures remain explicit. Inline
output keeps a bounded head/tail preview (including after wrapping), with hidden
lines indicated. F3 copies the full retained source and F4 opens scrollable
details with the full output and arguments; its ←/→ keys browse tool cards.

Edits show red `-` and green `+` replacement previews, context, relative line
numbers, and per-replacement change counts. These compare the submitted
`oldText`/`newText` strings, **not files on disk**: even after completion they are
labeled previews, not verified file diffs. Failed calls remain failed. Write
cards show submitted content without pretending that an overwrite is a new
file. No filesystem reads, new dependencies, or tool execution changes are
involved. Large replacements skip expensive matching and show before/after
lines instead; complete submitted replacements remain available in details.
Ctrl+F searches the same retained source, including output hidden behind the
preview, and returns at most 200 matching entries per keystroke.

Paint is a security boundary: ANSI/OSC control sequences, other non-display
bytes, and tabs are stripped or normalized before model or tool text reaches a
widget, including inside the inspector. Explicit copy actions use the raw
retained source, so copied output is what the tool or model produced.

Reading position belongs to the user. Scrolling up pauses automatic following
and shows a reading-back affordance; when new output arrives below the reading
position the row changes to "New output · Ctrl+End latest". Streaming updates,
reasoning collapse/expand, and terminal resize preserve a logical
`{entry, offset}` anchor instead of a raw row offset. Only Ctrl+End (or
scrolling back to the bottom) resumes following.

Markdown heights are measured at the current content width and remeasured after
terminal resize. Each response is parsed once per changed source/width, without
duplicating its source into 64-row widgets. Native cell and logical-line indexes
skip to the viewport; only visible rows are painted. Transcript offsets exceed
65,535 rows without a whole-response plain-text fallback. An individual logical
line exceeding Ratatui's `u16` scroll range uses styled grapheme wrapping instead
of word wrapping; complete raw source remains available for copy and search.
Native surface output is limited to 65,536 cells per render.

The status row shows honest turn state (`ready`, `starting`, `thinking`,
`responding`, `running <tool>`, `cancelling`, `cancelled`, `failed`) plus
available context/token/cache/cost metrics. Optional metrics are dropped before
working state, cancellation, or the composer when the terminal is narrow, and
the status row itself disappears on very short terminals. A `~` before cost
(for example `~$0.84`) marks a price-card estimate rather than
provider-reported billing. Missing metadata is omitted.

### Compaction

Manual (Ctrl+K) and automatic compaction show cards inline in the conversation,
not pinned above the input. Each card stays at its position between messages and
scrolls with the transcript. Progress updates the same card, distinguishing
context pressure from overflow and showing additional tightening passes. On
success it reports before/after token estimates; failures and cancellation are
explicit. The canonical conversation is not removed or replaced by the summary.

The summary stays collapsed: F4 enters transcript browsing, ↑/↓ selects a card,
Enter opens its full source in the scrollable inspector, and Y copies it.
Resuming a compacted session exposes its current checkpoint summary at the start
of the transcript, labeled as restored because its historical position and token
counts are unavailable. Live cards retain their chronological positions for the
current session view; they are not a persisted compaction archive. Drafts remain
editable and are never queued during manual compaction; Esc does not cancel that
synchronous session operation.

### Conversation tree (`/tree`)

Type `/tree` (or press F5) while idle to browse the session's conversation tree.
The picker is search-first: type to filter, ↑/↓ to move, Enter to select, Esc to
close without changing the conversation or the draft.

Rows are drawn with branch indentation, and the active position is marked. Rows
whose tool batch is incomplete are labeled *inspect only* and cannot be selected,
because navigating there would replay a tool or fabricate a result.

Selecting a user message moves to its parent and, when the composer is untouched,
fills it with that message; submitting the edit then creates a sibling branch.
Selecting another entry moves to it, and the start row returns to the empty
conversation before the first message. An existing non-empty draft is never
overwritten by a selected message; the notice says the draft was kept.

Navigation is committed before it is installed, so the selected position is
restored on `--resume` even when you exit without sending another prompt. The
picker states plainly that navigation does not undo workspace changes.

## Experimental limitations

This shell is an experimentation build. It intentionally does not implement:

- queued or steering prompts while a turn runs (the draft is kept, not queued);
- approval or permission prompts;
- session browsing, branching, or reconnect (a new session starts a fresh root scope, and the shell cannot yet list or reopen past sessions; on exit it prints the `--resume` command for the session it was attached to); note that in-session `/tree` branching is implemented and is distinct from session browsing;
- inline terminal-scrollback rendering (the TUI owns the alternate screen);
- a theme framework (colors are semantic but fixed), authoritative file diffs,
  or a plugin presenter registry;
- background search indexing (Ctrl+F is synchronous and capped).

Mouse capture is enabled for wheel scrolling, so native terminal selection
requires the terminal's mouse-override gesture (typically Shift-drag).
The non-TUI command path remains available for automation.

### Pinned ExRatatui fork

Until the width-aware Markdown measurement API is released in Hex, this
frontend uses the fork at
`ssh://git@git.makussu.de:2122/Makussu/ex_ratatui.git`, pinned to commit
`410c2e7`. The fork still declares version `0.13.1`, so the CLI configuration
forces an ExRatatui source build instead of loading the published precompiled
NIF. The direct `:rustler` dependency in `mix.exs` is required by that source
build.

Access to the fork and a Rust/Cargo toolchain are required. The Nix development
shell provides the toolchain:

```sh
cd frontends/tackle_cli
mix deps.get
mix compile --warnings-as-errors
```

The escript archive is suitable for non-TUI commands only: native libraries
cannot be loaded directly from its embedded ZIP. The frontend can switch back
to the released ExRatatui package once the measurement API is available there.

## Code layout

The TUI is split by surface rather than by layer. `Tackle.CLI.TUI` is the
coordinator: it owns the ExRatatui callbacks, the key-table routing, and the
process lifecycle, and everything else is a module that takes and returns
`Tackle.CLI.TUI.State`.

| module | owns |
| --- | --- |
| `TUI` | callbacks, key routing, process lifecycle |
| `TUI.State` | the state struct, mounting, adopting a session |
| `TUI.Viewport` | transcript/layout synchronization and scrolling |
| `TUI.RuntimeEvents` | projecting harness events into state |
| `Widgets.Input` / `native/tackle/src/widgets/input.rs` | native draft resource, editing, wrapping, and caret paint |
| `TUI.Composer` | draft editing and submission |
| `TUI.Browser` | transcript focus, selection, and copy |
| `TUI.Menu` | model, reasoning, and settings pickers |
| `TUI.Tree` | the `/tree` conversation picker and navigation outcomes |
| `TUI.Search` | transcript search |
| `TUI.Inspector` | the scrollable tool-output inspector |
| `TUI.Session` | root scope ownership and teardown |
| `TUI.View` | the scene and ordinary widgets |
| `TUI.StatusView` | status row, metrics, and hints |
| `TUI.Layout` | responsive regions for a terminal size |
| `Widgets.Conversation` / `native/tackle/src/widgets/conversation.rs` | immutable native history cells, Markdown layout, clipped viewport and selection paint |
| `TUI.Conversation` | transcript projection cache, anchors, and row scrolling |
| `TUI.MessageView` / `TUI.ToolView` | entry rendering and tool-card details |
| `TUI.Picker` / `TUI.Theme` / `TUI.Util` | menu filtering, palette, shared helpers |

Presentation is pure: a module that renders takes state and returns widgets,
and a module that handles input returns the next state plus the ExRatatui
reply. New behaviour belongs in the module that owns the surface, and the
`dispatch_base/3` clauses in `TUI` are where an addition to `Keybinds` fails
loudly until it is given behaviour.

## Development checks

```sh
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted
cargo test --manifest-path native/tackle/Cargo.toml
cargo fmt --manifest-path native/tackle/Cargo.toml --check
```

The custom input uses the existing Rust dependencies; the native conversation
adds `tui-markdown` (also used by ExRatatui). Both use the owned styled-row
surface bridge; no resources or pointers are shared with ExRatatui's NIF.
Attachments, history search, completions, selections, and Vim mode are not yet
implemented.

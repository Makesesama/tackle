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
mix tackle auth login openai-codex
mix tackle auth login deepseek
mix tackle run --model deepseek/deepseek-chat "Inspect this project"
mix tackle run --thinking high "Inspect this project"
```

DeepSeek login stores the key under the `deepseek` credential namespace. The
credential file is plaintext JSON protected by user-only filesystem permissions;
alternatively, set `DEEPSEEK_API_KEY`. When the terminal does not support hidden
input, the command falls back to a visible prompt.

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
| F4 | Details for the latest tool call, including pending calls. ←/→ browses previous/next tools; ↑/↓, PgUp/PgDn, Home/End scroll. Y copies raw output (arguments when no output exists), A copies tool arguments, Esc closes. |
| Ctrl+F | Transcript search over full retained message and tool source. Type a query, Enter/↓ next match, ↑ previous, Esc closes. The query is never sent to the agent. |
| Ctrl+T | Reveal or collapse supplied reasoning. |
| Page Up/Page Down, mouse wheel | Scroll the transcript. Ctrl+Home jumps to the oldest row; Ctrl+End returns to the newest row and resumes following. |

## Composer behavior

The composer is the native multiline `Textarea`, not a prompt field. It grows
with the draft's logical line count up to eight visible lines. The native
widget scrolls horizontally instead of soft-wrapping, so one logical line is
always one screen row and long lines are read by moving the caret rather than
by wrapping.

Bracketed paste lands as one edit and never submits. CRLF is normalized to `\n`;
lone CR is dropped before the edit. Ctrl+U undoes and Ctrl+R redoes a full
multiline paste. Unknown modified chords (for example Alt+G) are ignored by the
native widget. Key releases are ignored; key repeats apply to text and
navigation but not to submit, quit, or overlay shortcuts.

While a turn is active the composer is labeled "Draft · next turn (not queued)"
and Enter does not send. There is no queue, so the draft is explicitly reserved
for the next turn instead of being delivered to the running one. A failed
submit, failed reconfiguration, or rejected operation keeps the exact draft in
the composer.

## Transcript behavior

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
terminal resize. Long histories are sliced to the visible row range; long
Markdown responses retain their complete source and use bounded scroll windows
rather than splitting Markdown syntax across widgets. Responses beyond the
native 65,536-row scroll range fall back to bounded plain-text source instead
of crashing.

The status row shows honest turn state (`ready`, `starting`, `thinking`,
`responding`, `running <tool>`, `cancelling`, `cancelled`, `failed`) plus
available context/token/cache/cost metrics. Optional metrics are dropped before
working state, cancellation, or the composer when the terminal is narrow, and
the status row itself disappears on very short terminals. A `~` before cost
(for example `~$0.84`) marks a price-card estimate rather than
provider-reported billing. Missing metadata is omitted; context pressure is
informational only and automatic compaction is not implemented.

## Experimental limitations

This shell is an experimentation build. It intentionally does not implement:

- queued or steering prompts while a turn runs (the draft is kept, not queued);
- approval or permission prompts;
- session browsing, branching, or reconnect (a new session starts a fresh root scope, but the shell cannot yet list or reopen past sessions);
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
| `TUI.Composer` | draft editing and submission |
| `TUI.Browser` | transcript focus, selection, and copy |
| `TUI.Menu` | model, reasoning, and settings pickers |
| `TUI.Search` | transcript search |
| `TUI.Inspector` | the scrollable tool-output inspector |
| `TUI.Session` | root scope ownership and teardown |
| `TUI.View` | the scene and ordinary widgets |
| `TUI.StatusView` | status row, metrics, and hints |
| `TUI.Layout` | responsive regions for a terminal size |
| `TUI.Conversation` | transcript cache, anchors, and row scrolling |
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
```

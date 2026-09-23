# Tackle CLI

Terminal frontend and default product entrypoint for the Tackle developer
harness.

This is a separate Mix project so CLI dependencies and presentation concerns stay
out of the harness and `packages/tackle_lib`. The shipped CLI distribution
bundles the first-party `packages/tackle_codex` and `packages/tackle_deepseek`
adapters, configures them as available harness adapters, and then talks to the
`:tackle` application for
configuration, credential storage, scoped runtime ownership, and turn execution.
The CLI starts one root scope, addresses the root agent through a
`Tackle.Runtime.AgentRef`, and stops the complete scope on exit; it never stores
or checks a runtime PID.

The CLI may select a canonical model reference with `--model` and a reasoning
level with `--thinking` (`off`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`), but it does not load or select adapter modules directly.
Adapter availability is a harness and distribution concern.

Live tool rows update independently as each execution succeeds or fails, even
while other calls in the batch are still running. Bash output is shown as a
bounded live tail, and streamed tool arguments let write cards preview incoming
paths and content before execution starts. Rows stay in requested order;
execution status is transient progress, not confirmation of a durable commit.

The wrapped binary is currently a **fixed distribution**: Codex and DeepSeek
are compiled into it. It does not discover or load third-party plugins at
runtime. That keeps packaging separate from the future plugin-loading design.

## MCP connections (experimental)

`mix tackle mcp add NAME --stdio COMMAND --arg ARG` adds a local server;
`mix tackle mcp add NAME --http https://host/mcp` adds a Streamable HTTP
server. `mix tackle mcp list` and `mix tackle mcp remove NAME` manage definitions
in `$TACKLE_HOME/mcp.json` (not credentials). STDIO servers are connected and
their discovered tools are available to the root agent when starting a run;
configured subagents must explicitly list an MCP tool name to use it.

`mix tackle mcp auth login NAME` discovers the HTTP server's OAuth endpoints,
prints a browser authorization URL and waits on a loopback callback. Credentials
are stored in `$TACKLE_HOME/auth.json` under `mcp:NAME`; `mcp auth status`
and `mcp auth logout NAME` inspect/delete them. By default the authorization
server must support dynamic client registration; use `mcp auth login NAME
--client-id ID` for a pre-registered public client. The flow prints the
browser URL but does not open the browser itself.

Authenticated HTTP servers use the stored OAuth bearer token when establishing
an Anubis connection. The CLI refreshes expiring tokens before connecting and
updates the active HTTP transport with renewed tokens during long-running
sessions. Anubis debug logging is disabled by the CLI because it prints bearer
headers. While the TUI runs, its OTP console Logger handler is temporarily
filtered so unrelated Logger events cannot paint over the screen; the filter
is removed on exit. Direct writes to stdout/stderr from third-party code are
not caught by Logger filters and must be redirected at their source. Redirect
responses are not currently supported by Anubis 2.0's HTTP
redirect handler; configure the server's final MCP endpoint URL directly.

## Configured subagents

In addition to the built-in scout, reviewer, and worker, the CLI loads Markdown agent definitions
from `$TACKLE_HOME/agents/**/*.md` and the nearest project
`.tackle/agents/**/*.md` directory. Project definitions override user and
built-in definitions by name. Definitions configure the agent prompt, trusted
tool subset, model/thinking, timeout, iteration bound, advertisement, and
optional bounded delegation. See the root
[configured subagent documentation](../../README.md#configured-subagents) for
the file format and security boundaries.

## Default subagents

Every CLI coding scope enables `scout`, `reviewer`, and `worker` by default;
the former `explorer` profile has been removed. Scout performs quick read-only
reconnaissance, reviewer performs read-only code review, and worker can implement
changes with the harness's trusted coding tools. All have fresh conversation
context, no further delegation, a 20-iteration/five-minute budget, and share a
limit of two simultaneous children. They share the workspace. Scout and reviewer
are instructed not to edit it, but
**bash is not sandboxed or enforced read-only**. Profiles are configured by
`Tackle.Coding` in the harness package, not the frontend. Each built-in child request
uses the root's current model and thinking selection, including after resume or
a TUI model change. Already-running children retain their original selection.
Tools, prompts, limits, and conversation context remain separate; only model and
thinking follow the parent.

Children have a dedicated inline card showing the profile, resolved model,
assignment, explicit running/completed/failed status, and bounded findings or
error output. While one or more children are running, a minimal native task
sidebar opens beside the transcript and lists each active profile, resolved
model, assignment, current bounded activity, and elapsed time with an animated
running indicator; it closes when no child remains active. Parallel calls keep
independent cards in request order. F4 details retain full arguments and bounded
live activity until canonical findings arrive; search includes the assignment.
A live elapsed clock measures local
time since the frontend observed tool start, freezes at execution completion,
and disappears when canonical history replaces live progress. It is not provider
latency or durable timing. Cancellation of the parent clears live cards and
shows the turn cancellation; it does not claim the child completed.

Only returned findings are retained in the root journal; child transcripts and
forwarded progress are ephemeral. Footer and chart usage totals exclude child
usage. See the root
[default subagent documentation](../../README.md#default-subagents) for details.

## Single-file release

[Burrito](https://github.com/burrito-elixir/burrito) wraps this frontend and its
OTP release into one executable. Build the distributable from the repository
root with Nix; the target architecture is selected from the build host:

```sh
nix build .#tackle-cli
./result/bin/tackle --version
```

On Linux, `nix build .#tackle-cli-jail` builds a separate Bubblewrap wrapper
(`bin/tackle`)
around this same production binary, with host-daemon Nix build support. See
[production jailed package](../../README.md#production-jailed-package-on-linux)
for permissions, requirements, and the credential-free host smoke test. The
existing `jailed-tackle` command remains the development-checkout launcher.

The release has two Rust NIFs: ExRatatui and Tackle's native widgets. The Nix
package builds both from their locked sources with the target-specific Rust and
C toolchains, then assembles the release with the exact Erlang/OTP patch used by
Burrito's precompiled ERTS. The resulting executable is `result/bin/tackle`.

Burrito's Linux payload boots on musl, so neither a glibc NIF nor a release
assembled with a different OTP patch can run there. `nix/packages/burrito-runtime.nix`
pins the compiler and the [BEAM Machine](https://github.com/elixir-lang/beam-machine)
ERTS together. Do not bypass that pin by building under a newer development
shell and substituting an older `TACKLE_ERTS_VERSION`: OTP applications such as
`:crypto` can change version between patch releases, leaving Burrito's musl NIF
beside the assembled release's glibc NIF. The wrapper then boots on musl but
loads the glibc library and crashes.

The package's install check starts the real TUI under a pseudo-terminal in
addition to running informational commands. This exercises `:crypto` and both
Rust NIFs, which `--version`, `--help`, and `models` do not all load. When
updating the runtime pin, update the fixed ERTS hashes and keep the compiler and
BEAM Machine artifact on the same exact OTP patch.

Direct `mix release` remains useful while developing release configuration, but
it is not the distributable build: it uses the active shell's OTP and network
ERTS resolution. On Linux it also requires `TARGET_ABI=musl` for ExRatatui and
the Tackle NIF musl variables supplied by the Nix development shell.
`Tackle.CLI.Release.verify_linux_nifs/1`, wired between `:assemble` and
`&Burrito.wrap/1`, rejects glibc Rust NIFs and the shared `libgcc_s.so.1`
unwinder before wrapping.

Smoke-test the non-interactive path before publishing:

```sh
./result/bin/tackle --version
./result/bin/tackle --help
./result/bin/tackle models
# Open the TUI as well; Ctrl+C exits after startup.
./result/bin/tackle
```

`--version`, `--help`, and `models` do not exercise every OTP NIF used by the
TUI, so they are not sufficient on their own.

The binary extracts its ordinary OTP release into Burrito's per-user cache on
first run; use `./result/bin/tackle maintenance uninstall` when testing a
rebuilt binary with the same application version.

## Usage during development

From the repository root, enter the CLI app and fetch its dependencies once:

```sh
cd apps/tackle_cli
mix deps.get
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
mix tackle run --thinking max "Inspect this project"
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
`Tackle.Lib.LLM` plugin works without CLI changes. One-shot `run` commands show
compact event-driven progress on stderr when it is an interactive terminal; the
final answer remains the only stdout result, and redirected/non-terminal runs
stay free of progress and ANSI control sequences.
The progress renderer uses a command-local `Owl.LiveScreen` rather than Owl's
application-wide stdout screen.

`tackle sessions` defaults to the 20 most recent sessions and uses a borderless,
width-aware human layout. Narrow terminals switch to stacked summaries instead
of dropping or abbreviating session IDs. Use `--limit N` to request more rows,
`--format plain` for stable tab-separated output, or `--format json` for a
structured page including `next_cursor`; pass that value back through `--cursor`
to retrieve the next page. Human output honors `--color auto|always|never` and
`NO_COLOR`; plain and JSON output never contain ANSI sequences.

`tackle auth status` uses the same borderless output policy and shows each
provider's credential status and supported auth flows. `auth status` and `auth
usage` support `--format human|plain|json` and `--color auto|always|never`;
plain and JSON modes are stable, ANSI-free machine output. Login and logout
remain interactive and therefore require human output. Provider failures are
translated into actionable messages instead of exposing internal Elixir tuples.
DeepSeek login prompts for a key through the adapter and stores it under the
`deepseek` credential namespace;
`auth usage deepseek` reports the account balance, and `auth usage` without a
provider reports it for every provider that supports it. The credential file is
plaintext JSON protected by user-only filesystem permissions; alternatively, set
`DEEPSEEK_API_KEY`. When the terminal does not support hidden input, the command
falls back to a visible prompt.

The same `mix tackle` commands continue to work from this directory. Run
`mix tackle` without a prompt to open the supervised `ExRatatui.App` TUI.
The shell is transcript-first and fullscreen: a compact model header, a
border-light transcript, and a growing multiline composer. Reading position,
status/metrics and a quiet `? help` cue sit **below** the input bar, not above
it. `?` opens a shortcut reference when the draft is empty (or while browsing);
with a non-empty draft it inserts a literal question mark. Esc or ? closes the
reference. The bar uses a muted blue border while focused; turn state falls
back to the header on short terminals. Tiny terminals drop optional footer rows
and yield the input border to editable text. The status row combines input and
output token counts into a single `tokens in/out` segment; unavailable counts
are omitted rather than reported as zero.

## Keys (experimental)

| Key | Action |
| --- | --- |
| ? (empty draft or Browse) | Open the shortcut reference. Esc or ? closes it. In a non-empty draft, ? is inserted normally. |
| Enter | Send the draft when idle. While a turn is active the draft is kept but **not queued**. |
| Shift+Enter, Ctrl+Enter, Ctrl+J | Insert a newline. Ctrl+J is the reliable fallback because many terminals cannot distinguish Shift+Enter. |
| ↑ / ↓ | ↑ recalls older prompts even with a non-empty draft; ↓ walks toward the newest prompt and restores the draft you were writing. Outside history browsing, ↓ moves the caret. |
| Ctrl+P / Ctrl+N | Recall older/newer prompts from any draft. ↓/Ctrl+N past the newest prompt returns the draft you were writing. History is in-memory and capped at 100 prompts. |
| Esc | Close the open overlay first, then clear a non-empty draft; with an empty draft, request cancellation of the active turn. Esc never exits while idle. |
| Ctrl+C | Quit. Confirms first when an unsent draft or an active turn would be lost; quits immediately when idle with an empty draft. |
| Alt+N | Start a new session. Confirms first with a Y/N prompt; on confirm the current root scope stops (stopping an active turn with it) and a fresh session and scope start without restarting the shell. Durable history is not deleted—resume it later with `--resume`. |
| F1 | Search-first model selector (idle only). Type to filter, ↑/↓ to select, Enter to apply, Esc to close. |
| F2 | Reasoning-level selector (idle only). A reconfigure failure preserves the conversation and the draft. |
| F3 | Settings picker (currently empty). Copy source with Y in the F4 transcript browser instead. |
| F4 | Unified Browse: Transcript, Overview, Prompt, Context, Tools, Events. ←/→ or Tab/Shift+Tab switches pages. Transcript ↑/↓ selects entries, Enter inspects, Y copies source. Other pages scroll with ↑/↓, Page Up/Down, Home/End or wheel; R refreshes, Y copies. Esc/F4 returns to the draft. |
| F5, `/tree` | Open the conversation-tree picker (idle only). Search, ↑/↓, Enter to move; Esc closes. |
| F6 | Open cumulative settled token usage. Tab or ←/→ switches Current/This-week sessions, R reloads, Esc closes. |
| Ctrl+B / Alt+B (input bar) | Move the caret backward by one whitespace-delimited word. |
| Ctrl+F / Alt+F (input bar) | Move the caret forward by one whitespace-delimited word. |
| Ctrl+F (Browse transcript) | Search full retained message and tool source. Type a query, Enter/↓ next match, ↑ previous, Esc closes. The query is never sent to the agent. |
| Ctrl+K | Compact context manually while idle. The draft is retained. Manual compaction cannot currently be cancelled. |
| Ctrl+T | Reveal or collapse supplied reasoning. |
| Page Up/Page Down, mouse wheel | Scroll the transcript. Alt+< jumps to the oldest row; Alt+> returns to the newest row and resumes following. |

## Browse and local observability

F4 opens a single, Tackle-owned native Browse widget in the main pane—not a
separate diagnostics popup. It opens Transcript when messages exist, otherwise
Overview. Left/right or Tab/Shift+Tab cycles all six pages; Esc or F4 returns
to the composer without touching the draft. There is no separate F7/D shortcut.

Rust owns responsive page tabs, plain-text grapheme wrapping, scroll bounds and
viewport clipping. The transcript page reuses the existing immutable native
history cells and selection painting. Diagnostic pages retain immutable native
documents; incoming events do not re-layout or change their contents until R
refreshes or the page is reopened. Resize re-measures the retained source. Only
visible styled rows cross back into ExRatatui. Tiny panes prioritize content
over tabs; narrow tab bars show the active page and its position.

The Transcript page retains its usual copy, search, reasoning and Enter-to-inspect
actions. The remaining pages are read-only:

- **Overview:** session/turn correlation, activity, selected model and limits,
  reasoning, retry/compaction/tool policies, hooks, settled archive and branch
  usage, separate live-turn usage, and context pressure. Unknown values remain
  `nil`; estimated context and costs retain their estimation flags.
- **Prompt:** the configured composed system prompt, not a capture of later
  hook or adapter transformations.
- **Context:** the last settled model projection, including compactions,
  message IDs, timestamps, usage, text, supplied reasoning, and tool calls.
  Active-turn additions may not yet be present. Multimodal parts are counted,
  not dumped; F4 remains the active transcript and F5 the canonical tree.
- **Tools:** registered provider-neutral definitions, before per-turn hook changes.
- **Events:** the latest 500 lifecycle events received for the attached session,
  oldest first, with turn/message/tool correlation, emitter/receipt timestamps,
  and local monotonic elapsed milliseconds. Retry attempts and delays, tool
  execution versus settlement, compaction, failures, and terminal outcomes are
  visible. Streaming deltas are counted without copying their payloads. Dropped
  event counts are explicit. Elapsed time is **not provider execution latency**.

This is local UI observability using existing harness events, not a global
`:telemetry` collector, durable trace, or exact provider-request capture. Events
are not reconstructed on resume and reset on a new session. Event detail fields
are allowlisted, strings capped at 200 characters, and error bodies/tool I/O
omitted (inspect the transcript for retained output). Diagnostics do not fetch
credentials, dump arbitrary adapter options/context, or include raw usage,
provider metadata, or opaque continuation state. Prompt/context text and tool
arguments can themselves contain private information: inspect and copy locally
with care; copied pages are **not** automatically scrubbed support bundles.

## Composer behavior

The composer is Tackle's custom Rust `Input` widget in `native/tackle`, inspired
by the separation between Codex's textarea and higher-level composer. It grows
with the draft's **wrapped screen rows** up to eight visible rows, then scrolls
vertically to keep the caret visible. Wrapping uses grapheme boundaries (not
word boundaries), preserves source whitespace, and reserves a visible insertion
cell at the end of a full row. Resizing remeasures the draft and transcript.

Left/Right and Backspace/Delete operate on complete graphemes, including
combining marks and emoji. Up recalls prompt history even when a draft is
present; Down steps toward the saved draft while browsing history and otherwise
moves by visual row, retaining the preferred column. Ctrl+P/Ctrl+N also walk
history. Home/End and Ctrl+A/E move to logical line
boundaries; Ctrl+B/Alt+B and Ctrl+F/Alt+F move backward and forward by a
whitespace-delimited word; Ctrl+W deletes the preceding word. The caret is
hidden while browsing or using an overlay. Tabs paint as spaces and other
control characters as visible replacements without changing the submitted
source.

Bracketed paste lands as one edit and never submits. CRLF is normalized to `\n`;
lone CR is dropped before the edit. In the composer, Ctrl+V pastes clipboard
text or, if available, an image (PNG, JPEG, GIF, WebP, up to 5 MiB). A terminal
that pastes an image as a file path is also supported. Images appear as numbered
`[image-1]` tokens in the composer; text pastes of at least 1,000 bytes appear
as `[text-1]`, with separate counters for each type. Enter expands the tokens
before sending the full prompt to the agent. Smaller text pastes remain editable
as ordinary text. Clipboard images need
`wl-paste` (Wayland), `xclip` (X11), or `pngpaste` (macOS); text fallback on macOS
uses `pbpaste`. The CLI saves clipboard images in a private temporary directory
until it exits and expands image tokens into paths with a request to use the
`read` tool. Images
are **not** directly attached to user messages; the agent must read the file,
and those saved paths will not work after the CLI exits. Ctrl+U undoes and
Ctrl+R redoes a full multiline paste. Undo and redo each retain at most 100
snapshots / 8 MiB; a
programmatic draft replacement resets both histories. Unknown modified chords
(for example Alt+G) are ignored by the
native widget. Key releases are ignored; key repeats apply to text and
navigation but not to submit, quit, or overlay shortcuts.

Submitted prompts are appended to an in-memory history: newest first, capped at
100, with consecutive duplicates skipped. It survives a new session but is not
written to disk, so it is lost when the shell exits.

While a turn is active the composer is labeled "Draft · not queued"
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

The conversation uses a content-first layout, drawing on Codex's hanging message
gutters and Opal's compact, target-first tool headings. Assistant Markdown has a
small `●` gutter; plain user prompts keep a subtle background and `›` marker.
Wrapped continuations align with the text, not the marker, and a right margin
keeps prose off the terminal edge. Below four columns, message chrome yields to
content. Reasoning uses muted text and italic previews rather than an accented
heading.

The conversation renders assistant responses as Markdown, including while a
response is streaming. Tool calls and matching results share one card, identified
by call ID, with the command or path emphasized and the tool name subdued rather
than a JSON argument dump. Tool cards are borderless, with indented output instead
of raised bands or heavy rails. Completed calls use a quiet dot without
repeating "completed"; requested, running, and failed states remain explicit.
Truncated headers and hidden output use a quiet ellipsis; F4 still opens the
transcript browser. Successful tool output is subdued; failures remain explicit.
Successful reads collapse to a path-only card without dumping file contents into
the conversation. Successful Bash calls show at most two non-empty tail lines,
clipped rather than wrapped, with an ellipsis when output is hidden. Empty shell
output adds no body rows. Failures and unknown tools keep bounded diagnostic
previews. Failed edits show only the error,
not a replacement preview; their inspector retains the submitted arguments as
source. Completed subagents with a measured duration show just the elapsed
seconds instead of a completion label. Other inline output keeps a bounded head/tail preview (including after
wrapping), with hidden lines indicated. F4 browses entries: Y copies the full
retained source and Enter opens scrollable details with the full output and
arguments; its ←/→ keys browse tool cards.

Edits use compact, borderless replacement previews: muted line numbers, soft red
`-` and green `+` markers, and per-replacement counts in one heading. Code stays
neutral on the terminal background; only changed words receive a subtle tint.
Unchanged context is subdued. These compare the submitted
`oldText`/`newText` strings, **not files on disk**: even after completion they are
not verified file diffs. Failed calls remain failed. Write
cards show submitted content without pretending that an overwrite is a new
file. No filesystem reads, new dependencies, or tool execution changes are
involved. Large replacements skip expensive matching and show before/after
lines instead; complete submitted replacements remain available in details.
While the transcript browser is focused, Ctrl+F searches the same retained
source, including output hidden behind the preview, and returns at most 200
matching entries per keystroke.

Paint is a security boundary: ANSI/OSC control sequences, other non-display
bytes, and tabs are stripped or normalized before model or tool text reaches a
widget, including inside the inspector. Explicit copy actions use the raw
retained source, so copied output is what the tool or model produced.

Reading position belongs to the user. Scrolling up pauses automatic following
and shows a reading-back affordance; when new output arrives below the reading
position the row changes to "New output · Alt+> latest". Streaming updates,
reasoning collapse/expand, and terminal resize preserve a logical
`{entry, offset}` anchor instead of a raw row offset. Only Alt+> (or
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

F6 opens a modal usage chart without shrinking the transcript. Current mode
covers the current session's complete branch archive; All sessions merges every
durable journal by assistant-message timestamp and removes exact history copies
introduced by session forks. Current mode accumulates from the beginning of the
session; All sessions accumulates only the current UTC calendar week beginning
Monday at 00:00. The total-token line never decreases between buckets. Its
summary separates uncached input, output, combined cache-read/write tokens, and
available provider-reported or price-card-estimated cost; `~$` marks an estimate
and unavailable cost is not invented. All journals are replayed with bounded
concurrency. Successful Current/All snapshots are cached for instant mode
switching, invalidated after a settled turn, and bypassed by R. An in-flight
response appears only after it settles. Loading, empty, partial, and error states
remain inside the overlay. The implementation uses ExRatatui's built-in `Chart`
widget and adds no custom native widget.

### Compaction

Transient provider-message failures retry automatically with cancellable
exponential backoff. If a streamed attempt fails, its provisional text is
cleared before the replacement attempt begins; settled earlier timeline entries
are retained.

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
- background search indexing (browser Ctrl+F search is synchronous and capped).

Mouse capture is enabled for wheel scrolling, so native terminal selection
requires the terminal's mouse-override gesture (typically Shift-drag).
The non-TUI command path remains available for automation.

### Native dependencies

The frontend uses the released ExRatatui package and its precompiled NIF during
normal development. Tackle's transcript, input, browse, and other native widgets
live in a separate Rustler crate under `native/tackle`; that crate measures and
renders assistant Markdown directly, without sharing resources or ABI with
ExRatatui. The direct `:rustler` dependency and a Rust/Cargo toolchain are
therefore still required. The Nix development shell provides the toolchain:

```sh
cd apps/tackle_cli
mix deps.get
mix compile --warnings-as-errors
```

The escript archive is suitable for non-TUI commands only: native libraries
cannot be loaded directly from its embedded ZIP.

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
| `Widgets.Subagents` / `native/tackle/src/widgets/subagents.rs` | native active-task sidebar, wrapping, clipping, and minimal chrome |
| `TUI.Composer` | draft editing, submission, and history recall |
| `TUI.History` | the in-memory prompt history and its browsing position |
| `TUI.Browser` | unified Browse navigation, frozen pages, transcript selection and copy |
| `Widgets.Browse` / `native/tackle/src/widgets/browse.rs` | native page tabs, document viewport and scroll bounds |
| `TUI.Diagnostics` / `TUI.Observations` | diagnostic projections and bounded local lifecycle history |
| `TUI.Menu` | model, reasoning, and settings pickers |
| `TUI.Tree` | the `/tree` conversation picker and navigation outcomes |
| `TUI.UsageChart` | async durable usage loading, UTC bucketing, and chart popup |
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

# Tackle CLI

Terminal frontend and default product entrypoint for the Tackle developer
harness.

This is a separate Mix project so CLI dependencies and presentation concerns stay
out of the root harness and `packages/tackle_lib`. The shipped CLI distribution
bundles first-party plugins such as `plugins/tackle_codex`, configures them as
available harness adapters, and then talks to the root `:tackle` application for
configuration, credential storage, scoped runtime ownership, and turn execution.
The CLI starts one root scope, addresses the root agent through a
`Tackle.Runtime.AgentRef`, and stops the complete scope on exit; it never stores
or checks a runtime PID.

The CLI may select a canonical model reference with `--model` and a reasoning
level with `--thinking`, but it does not load or select adapter modules directly.
Adapter availability is a harness and distribution concern.

## Usage during development

```sh
mix deps.get
mix tackle --help
mix tackle models
mix tackle auth status
mix tackle auth login openai-codex
mix tackle run --thinking high "Inspect this project"
```

Run `mix tackle` without a prompt to open the supervised `ExRatatui.App` TUI.
Type a prompt and press Enter to submit it; press F2 while idle to select the
model and thinking level, press Esc to cancel an active turn or exit while idle,
and press Ctrl+C to exit at any time. Scroll the conversation with Page Up/Page
Down or the mouse wheel; Ctrl+Home jumps to the oldest message and Ctrl+End
returns to the newest message and resumes automatic following. Press F3 to open
the keyboard copy menu, use Up/Down to select a message, then press Y or Enter
to copy it through OSC 52; press A to copy the full conversation. Mouse capture
is enabled for wheel scrolling, so native terminal selection requires the
terminal's mouse-override gesture (typically Shift-drag). The conversation
renders assistant responses as Markdown, including while a response is
streaming, and shows tool arguments, execution status, and concise result or
error previews. Markdown heights are measured at the current content width,
then remeasured after terminal resize. Long histories are sliced to the visible
row range; long Markdown responses retain their complete source and use bounded
scroll windows rather than splitting Markdown syntax across widgets. Responses
beyond the native 65,536-row scroll range fall back to bounded plain-text source
instead of crashing. Model and thinking changes preserve the settled
conversation. The footer shows current
context pressure and aggregate session input/output when available, plus the
Pi-compatible token-weighted prompt-cache hit rate and monetary cost. A `~`
before cost (for example `~$0.84`) marks a price-card estimate rather than
provider-reported billing. Missing metadata is omitted, and context pressure is
informational only—automatic compaction is not implemented.

### Local ExRatatui fork

Until the width-aware Markdown measurement API is released in Hex, this
frontend intentionally uses the local `../../repos/ex_ratatui` fork at commit
`410c2e7`. The fork still declares version `0.13.1`, so the CLI configuration
forces an ExRatatui source build instead of loading the published precompiled
NIF. The direct `:rustler` dependency in `mix.exs` is required by that source
build.

The fork must be present when developing the TUI, and a Rust/Cargo toolchain is
required:

```sh
# from the repository root, place the approved checkout at repos/ex_ratatui
cd frontends/tackle_cli
mix deps.get
mix compile --warnings-as-errors
```

The escript archive is suitable for non-TUI commands only: native libraries
cannot be loaded directly from its embedded ZIP. A portable checkout should
switch back to the released ExRatatui package once the measurement API is
available there.

## Development checks

```sh
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted
```

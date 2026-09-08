# Tackle CLI

Terminal frontend and default product entrypoint for the Tackle developer
harness.

This is a separate Mix project so CLI dependencies and presentation concerns stay
out of the root harness and `packages/tackle_lib`. The shipped CLI distribution
bundles first-party plugins such as `plugins/tackle_codex`, configures them as
available harness adapters, and then talks to the root `:tackle` application for
configuration, credential storage, session ownership, and turn execution.

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
returns to the newest message and resumes automatic following. The conversation
follows streaming reasoning summaries and responses and shows tool arguments,
execution status, and concise result or error previews. Model and thinking
changes preserve the settled conversation. When the provider reports
prompt-cache usage, the footer shows the latest token-weighted hit rate as
`CH<n.n>%`, matching Pi's
metric. This development task runs through Mix so ExRatatui's
native library remains available as a real file.
The escript archive is suitable for non-TUI commands only: native libraries
cannot be loaded directly from its embedded ZIP.

## Development checks

```sh
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted
```

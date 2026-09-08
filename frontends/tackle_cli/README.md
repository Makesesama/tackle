# Tackle CLI

Terminal frontend and default product entrypoint for the Tackle developer
harness.

This is a separate Mix project so CLI dependencies and presentation concerns stay
out of the root harness and `packages/tackle_lib`. The shipped CLI distribution
bundles first-party plugins such as `plugins/tackle_codex`, configures them as
available harness adapters, and then talks to the root `:tackle` application for
configuration, credential storage, session ownership, and turn execution.

The CLI may select a canonical model reference with `--model`, but it does not
load or select adapter modules directly. Adapter availability is a harness and
distribution concern.

## Usage during development

```sh
mix deps.get
mix run -e 'System.halt(Tackle.CLI.Main.main(System.argv()))' -- --help
mix run -e 'System.halt(Tackle.CLI.Main.main(System.argv()))' -- models
mix run -e 'System.halt(Tackle.CLI.Main.main(System.argv()))' -- auth status
mix run -e 'System.halt(Tackle.CLI.Main.main(System.argv()))' -- auth login openai-codex
mix run -e 'System.halt(Tackle.CLI.Main.main(System.argv()))' -- run "Inspect this project"
```

Build the local escript entrypoint:

```sh
mix escript.build
./tackle --help
```

## Development checks

```sh
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted
```

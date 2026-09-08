# Tackle CLI

Terminal frontend for the Tackle developer harness.

This is a separate Mix project so CLI dependencies and presentation concerns stay
out of the root harness and `packages/tackle_lib`. It depends on the root
`:tackle` application for configuration, adapter loading, session ownership, and
turn execution.

The CLI may select a canonical model reference with `--model`, but it does not
load or select adapter modules directly. Adapter availability is configured in
the root harness.

## Development

```sh
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted
```

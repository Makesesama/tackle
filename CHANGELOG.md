# Changelog

Notable changes to Tackle are recorded here. This repository contains separate Mix projects under `packages/` and `apps/`; the entries below describe the repository as a whole. A version in a Mix project is not, by itself, a published package or a tagged release.

## Unreleased

### Added

- Added an MIT license and this changelog.
- Added `packages/tackle_openrouter`, an OpenRouter provider adapter (`openrouter/<vendor>/<model>`) with streamed reasoning and `reasoning_details` replay, automatic Anthropic prompt caching, session-sticky routing, and reported billing cost. The CLI and web distributions bundle it.
- `config.json` accepts `provider_options`, adapter-keyed settings that the harness passes to adapters as the `:provider_options` LLM option (credential-like keys are rejected). The OpenRouter adapter reads per-model provider routing from it.

### Release preparation

- The initial `0.1.0` release has not been tagged. Installation instructions, supported distribution paths, and release validation are still to be finalized.

## Initial development (unreleased)

- Split the reusable agent library into `packages/tackle_lib` (`:tackle_lib`, `Tackle.Lib.*`) and introduced `packages/tackle` for the developer harness. This is a breaking change for users of the former `:tackle` library identity: update package paths, module references, and application configuration to `:tackle_lib`.
- Added `packages/tackle_runtime` for scoped OTP orchestration, including subagents and workflows.
- Added the Codex provider adapter and optional DeepSeek adapter, plus separate MCP client, Anubis server bridge, and Phoenix integration packages.
- Added the CLI and web applications. The CLI's Burrito build is a fixed distribution; loading third-party plugins into the binary is not yet supported. Neither app's presence implies a stable, published distribution.

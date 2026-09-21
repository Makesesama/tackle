# Plugins and extensions

Status: agreed architectural direction, not implemented functionality.

This document complements [the architecture specification](architecture-spec.md).
It records the plugin-loading decisions; exact configuration syntax and public
function signatures remain to be designed.

## Ordinary Elixir code

A plugin is ordinary Elixir code that extends Tackle. Users should be able to
place an Elixir file or a normal Mix project at a path, register that path in
configuration or enable discovery for its directory, and use it without
creating a special plugin package.

The intended workflow is:

1. Write or obtain an Elixir file or Mix project.
2. Configure its path, or place it in a configured discovery directory.
3. Start Tackle, which prepares and loads the extension and connects its
   functionality to the harness.

There is no required plugin manifest, custom bundle format, or mandatory
`Tackle.Plugin` behaviour. Users should not need to build a distribution
artifact or rebuild Tackle just to add an extension.

## Public APIs rather than a hard plugin interface

Extensions use documented, well-designed module APIs. They can provide tools,
provider adapters, hooks, or other harness functionality without implementing a
universal plugin entrypoint or lifecycle contract.

Existing capability-specific library contracts remain useful: a provider
adapter implements the provider contract, and a tool implements the tool
contract. These do not imply an additional plugin wrapper.

The harness should expose small, explicit APIs for connecting those capabilities.
Prefer explicit configuration and harness/session context over hidden global
state. Public APIs should be distinguished from implementation details; loading
Elixir code does not make every internal module a stable extension API.

First-party plugins use the same public APIs as user-supplied extensions. Codex
has no privileged path through the engine.

## Loading and registration

Loading code and registering its functionality are separate concerns:

- **Loading** makes modules available, preparing a Mix project when necessary.
- **Registration** connects tools, adapters, hooks, or services to the harness.

Support explicit extension paths and automatic discovery within configured
extension directories. Discovery locates code; it does not imply that Tackle
can infer the purpose of every module it finds.

Configuration can identify the modules to use, and extension code can use
public APIs to register functionality. The exact registration API and any
optional project entry-script convention are not decided yet. Do not require a
custom project structure beyond an ordinary Mix project.

## Ownership and frontend independence

The harness package in `packages/tackle/lib/tackle` owns configuration reading, extension discovery,
project preparation, loading, and composition. There is no separate plugin
runtime package.

The reusable library provides the engine and capability contracts. Applications
using that library to build their own harnesses do not need to adopt our loader.

CLI and future web frontends use the same configured harness. Plugin loading
must not depend on terminal input, terminal rendering, Phoenix, or a particular
frontend. Stateful extensions use normal OTP supervision rather than a parallel
plugin lifecycle framework.

## Mix projects and Burrito

For now, users may be required to have Elixir and Mix installed. Tackle can use
that local toolchain to prepare user-supplied Mix projects. Users should not
need to manually assemble compiled plugin bundles.

A Burrito executable does not remove this development-toolchain requirement
for project extensions. Providing a managed toolchain, embedding Mix, and
supporting installation with only the Tackle binary are deferred decisions.
They should not drive the initial extension API or block the simple local
workflow.

Dependency resolution, build caching, compatibility checks, and actionable
build errors will need implementation design. Native dependencies may require
additional build tools. No support for arbitrary dependency combinations or
cross-platform native plugins is promised by this document.

## Trust and scope

Loaded Elixir extensions execute with the privileges of the Tackle process;
there is no in-process security sandbox. Automatic discovery should be limited
to explicitly trusted directories, not silently execute code from any repository
the user opens.

Initial loading is startup-oriented. Hot reloading, unloading, a plugin
marketplace, and a separate package-management ecosystem are not requirements
for this design.

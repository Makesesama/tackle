# Optional conversation trees

Status: implemented first version. The library owns branching semantics
(`Tackle.Lib.Tree`, `Tackle.Lib.Tree.Navigator`, `Tackle.Lib.Tree.Committer`),
the root harness owns durable records and runtime coordination
(`Tackle.Session.Tree`, the `tree.enabled`/`tree.navigated` events, and the
tree-aware projection/loader), and the CLI owns the `/tree` picker. Steps 1–6 of
the sequence below are implemented with tests; step 7 documents the result. The
"Later increments" and "Follow-up" sections remain deliberately deferred.

This advances the same-session branching previously deferred in
[SESSION_ARCHITECTURE.md](SESSION_ARCHITECTURE.md#15-forking-and-lineage). It does
not replace `:disk_log`, independent session forks, or the scoped runtime.

## 1. User experience and scope

A tree preserves alternative conversation paths within one session:

```text
user: Investigate the cache
└─ assistant: Two possible approaches
   ├─ user: Try A
   │  └─ assistant: Result A
   └─ user: Try B
      └─ assistant: Result B  <- active position
```

`/tree` browses this history. Selecting an earlier user message moves to its
parent and offers that message as editable input; submitting the edit creates a
sibling branch. Selecting another resumable entry moves to that entry. Selecting
the current position is a no-op. Returning before the first message produces an
empty active conversation without deleting history.

The model receives only the selected path's context, including applicable
compactions. Navigation does not execute a turn, repeat tools, undo file edits,
restore runtime processes, or rewind host authorization/configuration.

### First usable version

- Opt-in tree history in `Tackle.Lib`, usable without the root harness or OTP.
- Root CLI conversations enable it once durable integration is complete.
- Stable entries, parent links, an active position, and branch enumeration.
- Navigation and continuation with no loss of alternative paths.
- Branch-aware compaction and provider context.
- Durable navigation, crash recovery, and legacy linear-session loading.
- An idle-only `/tree` picker with active-path indication, text search, basic
  user/all-entry filtering, inspection, and user-message editor refill.
- Unsafe continuation points remain inspectable but cannot be selected for
  execution; the UI explains why.

### Later increments

- Labels/bookmarks, folding, additional filters, and configurable shortcuts.
- Optional summaries of the branch being left, including custom instructions.
- Extracting just one selected path into a new independent session.
- Navigation while a response is streaming, with explicit cancellation and
  settlement before switching. Initially the user must cancel/wait separately.

No Git/workspace rollback, branch merging, parallel execution of multiple leaves,
provider-specific tree support, new dependencies, or persistence framework is
part of this work.

## 2. Ownership

| Layer | Owns |
| --- | --- |
| `packages/tackle_lib` | Tree values and invariants; settled-message insertion; active-path and model-context projection; navigation validation and state transition; compaction integration; provider-neutral change records and persistence seam. |
| Root `Tackle` | Plain-data codecs; journal validation/commit/sync; recovery and replay orchestration; serialized runtime operations; catalog/search; durable session APIs. |
| `frontends/tackle_cli` | `/tree`, selection and rendering, filters, editor drafts, notices, and applying authoritative snapshots. |
| Other hosts, including Phoenix | Their own storage and runtime adapters using the same library rules. No root-harness dependency is required. |

The root must decode validated records into library values and invoke the shared
projection rules. It must not copy the compaction/context algorithm or maintain
a second implementation of branching. Journal lifecycle validation and tool
execution audit remain host responsibilities.

## 3. Proposed library contracts

### Tree data and projections

Introduce a small immutable `Tackle.Lib.Tree` value with stable entry IDs,
parent IDs, chronological ordering, and an active entry ID (or `nil` before the
root). Initial entry kinds are settled messages and compactions. A compaction is
an entry because navigating before or after it must produce different model
contexts even when no new message followed it.

Message entries should reuse existing message IDs rather than mint a parallel
identity. Compaction entries reuse their compaction IDs. Enforce uniqueness
across entry kinds. Keep payloads stored once in the canonical tree; any lists
on state are derived projections, not independently editable histories.

Core invariants:

- An entry references an existing parent or `nil`; multiple roots are valid.
- IDs are unique, parent chains are acyclic, and ordering is deterministic.
- Only settled messages enter history; streaming deltas never become nodes.
- An append attaches to the active position and advances it.
- Navigation changes the active position without modifying existing entries.
- Model projection follows ancestry, not chronological append order.
- Shared ancestors are neither copied nor double-counted.
- Deep histories must not require recursively traversing the entire tree on
  every append. Start with simple indexes; avoid whole-state snapshots per node.

Use one entry point for applying validated tree changes, shared by live execution
and replay. Separate full-tree enumeration, active transcript, and model context
readers explicitly.

### State and reader semantics

Proposed opt-in shape: `Tackle.Lib.new(tree: true)` or explicit tree options.
Default remains disabled for existing library users. A restored tree session
must not silently become linear if a host omits the option: require tree support
or return a typed error.

Recommended semantics for tree-enabled state:

| Surface | Meaning |
| --- | --- |
| Canonical tree | All settled entries on all branches. |
| `State.messages` / `Tackle.Lib.messages/1` | Active path's complete transcript, not compacted. |
| `State.model_messages` | Active path's provider context, with applicable compactions. |
| `last_answer/1` | Last answer on the active path. |
| `usage/1` | Aggregate assistant-message usage across the entire tree, counted once per message. |
| Explicit branch usage reader | Assistant-message usage on the active path. |
| `context_usage/1` | Pressure for the current model projection only. |

Linear mode retains current behavior. Document that `State.messages` is no longer
the entire session archive in tree mode; consumers needing history must use the
tree reader. Auxiliary summarizer usage remains separately identified rather
than being disguised as assistant-message usage.

Finalize these public semantics and review affected consumers before coding.
Do not silently redefine existing linear readers, accept inconsistent externally
mutated state, or introduce an unrequested breaking migration. Provide a
validated restoration path for tree-enabled hosts instead of requiring direct
struct field replacement.

### Navigation transaction

The library prepares a transition against an expected tree revision/position,
validates the destination, constructs the new projections, and resets transient
turn state. The host-supplied committer persists the change before the library
returns an installed state. A missing committer is valid only for explicitly
in-memory use; the durable harness always supplies one.

Use the existing compaction committer pattern as a reference, not permission to
replace all extension contracts with a generic registry. Proposed operations
are tree inspection, navigation preparation, committed navigation, and replay
application. Exact module/function names are settled in step 1.

A navigation result identifies the selected entry and effective destination;
it can expose the selected message for the frontend to turn into an editor
draft. The library does not own editor widgets or overwrite drafts.

Expected failures include tree disabled, unknown entry, invalid history,
unsafe continuation boundary, stale transition, and durable commit failure.
A failed validation or commit leaves the accepted state unchanged. Events and
successful runtime snapshots are published only after the navigation commits.

The library rejects visibly active state, but immutable state alone cannot know
whether another process is executing a copy. Hosts must serialize navigation,
turns, configuration changes, and compaction. The root also blocks navigation
while interruption recovery is unresolved.

### Safe continuation

For the first version, require a structurally complete tool-call/result boundary.
Do not navigate to an assistant tool-call entry or partial tool-result batch and
then silently replay tools, fabricate results, or send malformed provider
history. Offer inspection and a nearby valid selection instead.

Retain canonical provider metadata for audit, but derive the destination's
provider context deliberately. Reuse compaction's established metadata-reset
rules where applicable. Test branch switches and model switches through the
normal adapter seam; never reuse sibling-branch continuation data or treat the
last chronological generation as the current context checkpoint.

Reset transient error, pending assistant, snapshot, iteration, and retry state
as appropriate without restoring historical credentials, tool registries,
authorization context, Tasks, or executable configuration. Current host-selected
model/thinking settings remain in effect for the first version.

### Compaction

Record compactions on the active ancestry. Project only those records encountered
on the selected path. Returning before a compaction restores the uncompacted
context; returning after it restores the same summary and retained tail without
calling the summarizer again. Sibling branches cannot inherit later compactions
from each other. Shared ancestral compactions remain applicable.

Integrate tree insertion with the existing compaction durability transaction:
one compaction must not require two separately acknowledged durable writes.
Use the same projection helper during live installation and replay. Preserve
canonical messages and reset only derived context metadata at context boundaries.

## 4. Durable harness integration

Keep the existing versioned append-only journal and one supervised writer.
Extend the durable schema to represent tree enablement, entry parentage, and
active-position changes. Exact event names/version changes belong to step 1.

- Persist message payload and its parent link together through the existing
  `after_message` hook boundary. The hook currently receives the settled state;
  use that to obtain the library-generated entry rather than guessing parentage
  from the last journal commit.
- Include compaction parentage in the existing compaction commit.
- Commit and sync navigation even if the user exits without sending another
  prompt. Resume must restore that selected position, including `nil`.
- Keep journal sequence (audit order) separate from tree ancestry. Turn starts,
  tool intents, recovery, and session metadata are not automatically tree nodes.
- Validate expected tree revision/position before accepting a transition.
- Continue failing closed on persistence failures. A crash after sync but before
  state installation is resolved by replaying the committed transition.
- Preserve unresolved tool-effect recovery independently of the chosen branch;
  navigation must not hide an interrupted execution.
- Browsing an empty provisional session writes nothing and preserves deferred
  session materialization.

Expose PID-free root operations for reading a tree and navigating it through an
`AgentRef`. Update session snapshots and publish a correlated navigation outcome
so all attached frontends refresh from the same settled state. Do not restart the
scope or switch session identity merely to change branches.

### Compatibility, forks, and catalog

- Existing linear journals still load unchanged. Build their initial chain from
  validated settled messages and compactions in commit order, retaining IDs.
- Enabling branching for an existing durable session is an explicit versioned
  transition before tree-specific writes. Do not rewrite the source file.
- Older readers must reject required tree events rather than flatten branches.
- Preserve current `fork_session/2` sequence-based behavior: a fork copies the
  validated journal prefix, including its tree and selected position. It remains
  self-contained after the parent is deleted. A selected-path-only fork is a
  separate later API, not a silent change to `:seq` semantics.
- Search continues indexing user/assistant text across the complete archive,
  excluding reasoning, provider state, arguments, and tool output. Shared
  messages count once; switching branches must not remove search results.
- Keep archive counts and aggregate usage distinct from active-path context and
  latest generation. Reset cache-reuse comparisons at non-append-only context
  switches rather than comparing unrelated branches.
- Retain current configuration persistence semantics; tree navigation does not
  restore old executable configuration.

## 5. Implementation sequence

### Step 1 — Contract and compatibility fixtures

Audit callers of `State.messages`, `model_messages`, `usage`, `last_answer`, state
restoration, message settlement, and compaction in all four consumers: library,
root, Phoenix, and CLI (plus adapter assumptions in Codex).

Finalize state/reader semantics, navigation boundary rules, change records,
restoration API, and journal upcasting rules. Identify any unavoidable breaking
changes and get approval before implementation.

Acceptance: agreed contracts and deterministic fixtures for linear history,
branching, root reset, tool batches, compaction, and interrupted turns. Fixtures
must use synthetic messages, not private conversation logs.

### Step 2 — Pure tree and projection model

Implement tree construction, append, traversal, active-position selection,
validation, and replay application under `packages/tackle_lib`. Add validated
restoration of tree state and derive transcript/model projections through one
implementation.

Acceptance: branching preserves siblings; invalid parents/duplicate IDs/cycles
are rejected; deterministic deep-tree traversal works; switching back produces
the same transcript and model context. No storage or OTP processes are needed.

### Step 3 — Loop, navigation, compaction, and accounting

Wire opt-in tree state into `State.add_message/2`, settled-message hooks, the
public facade, compaction, and context/usage readers. Implement the navigation
transaction and persistence seam. Keep one agent loop and disabled-mode behavior.

Acceptance: fake-adapter tests prove only active context is sent, including after
compaction and branch switches. No tool is re-executed by navigation. Failed
commits do not install state. An independent in-memory host can branch and run
without root modules. Existing linear tests remain green.

### Step 4 — Journal schema and shared replay

Extend `Tackle.Session.Codec`, `Log`, `Journal`, `Persistence`, `Compaction`,
`Projection`, and `Loader` as needed. Map validated durable records onto the
library's change application; retain host audit/recovery validation separately.
Add legacy enablement, fork, and catalog handling.

Acceptance: close/resume reproduces the full tree, active position, and model
context, including navigation with no following prompt. Old linear fixtures
load without rewrites. Forks survive parent deletion. Corruption, stale parents,
unsupported required versions, write errors, and sync errors fail explicitly.

### Step 5 — Serialized runtime API

Add tree inspection/navigation to the root facade and `Tackle.Session`, with
idle/recovery gates and authoritative snapshots. Integrate snapshot statistics
and notification semantics without exposing journal PIDs.

Acceptance: racing submit/navigation/compaction cannot install competing states;
recovery remains blocking; durable failures follow existing fail-closed scope
behavior; multiple subscribers see the committed destination consistently.

### Step 6 — CLI `/tree`

Reuse existing command, picker, inspector, and async-operation patterns. Add a
tree-specific renderer where indentation/branch connectors require it. Preserve
selection by entry ID and expose active position, search, filtering, and unsafe
boundary notices. Rebuild conversation/compaction cards from the destination
snapshot, not chronological indexes from the old branch.

Keep an existing non-empty composer draft unless the user explicitly chooses to
replace it. An untouched composer receives selected user text. Escape leaves
conversation state and draft unchanged. Show a clear notice that navigation does
not undo workspace changes.

Acceptance: CLI interaction tests cover new branch creation, returning to an old
branch, root reset, empty trees, search/filter selection, existing drafts,
cancellation of the picker, runtime rejection, failure results, and resume.
No provider calls are needed for these tests.

### Step 7 — Documentation and downstream verification

Update library/root/CLI READMEs, the session architecture, and relevant Phoenix
integration guidance to describe implemented behavior. Clearly distinguish
whole-tree archive, active transcript, and model context, and document any
approved compatibility changes.

Acceptance: examples work for both an in-memory library host and the durable CLI;
all affected project checks pass, or exact blockers are reported. Do not describe
later features as supported.

### Follow-up — Labels and branch summaries

Only after the first version is complete, add labels/folding and optional branch
summaries. A summary covers the old branch back to the common ancestor and is
attached at the effective destination. Keep summary generation provider-neutral,
account for its usage separately, support cancellation, and commit summary plus
navigation atomically. Cancellation/failure leaves the original position intact.

Reuse summarizer plumbing where appropriate, but do not apply compaction's
prefix-replacement semantics to a branch summary: they are different operations.

## 6. Validation matrix

Tests use deterministic IDs, fake adapters/tools, fake committers, and temporary
journals. Highest-priority regressions:

1. Linear opt-out behavior, public readers, and existing hooks remain unchanged.
2. Re-editing a user message creates a sibling without duplicating ancestors.
3. Navigation before the first message survives restart without losing history.
4. Model prompts never contain unselected sibling content or summaries.
5. Compaction before/after a fork point replays identically to live execution.
6. Tool batches cannot be split into unsafe executable contexts, including
   sequential/concurrent execution and cancelled/failed turns.
7. Navigation cannot bypass unresolved external-effect recovery.
8. Duplicate IDs, invalid parents, invalid compaction provenance, and unsupported
   schemas are rejected rather than repaired by dropping entries.
9. Commit failure preserves accepted state; crash after commit and before install
   restores the new state. Existing write-before-effect barriers remain intact.
10. Archive usage/search include all branches once; context usage and latest
    context checkpoint follow the selected projection, including model switches.
11. Fork, deletion, journal repair, and provisional-session behavior remain valid.
12. Independent hosts can persist/replay library tree changes without importing
    root modules or copying projection logic.

Run focused tests at each step, then the affected separate projects from a
configured `nix develop` shell:

```sh
mix compile --warnings-as-errors
mix test
mix format --check-formatted

(cd packages/tackle_lib && mix compile --warnings-as-errors && mix test)
(cd packages/tackle_lib && mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}')

(cd packages/tackle_phoenix && mix compile --warnings-as-errors && mix test)
(cd packages/tackle_phoenix && mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}')

(cd plugins/tackle_codex && mix compile --warnings-as-errors && mix test)
(cd plugins/tackle_codex && mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}')

(cd frontends/tackle_cli && mix compile --warnings-as-errors && mix test)
(cd frontends/tackle_cli && mix format --check-formatted)
(cd frontends/tackle_cli && mix escript.build)

git diff --check
```

Fetch dependencies only when needed. Run a manual terminal smoke test with a fake
adapter for tree navigation and restart; no credentials or paid model calls are
required. Report checks not run and environmental blockers honestly.

## 7. Reference behavior

The local Pi reference is under `repos/pi/packages/coding-agent/`:

- `docs/sessions.md`: `/tree` selection behavior and distinction from `/fork`.
- `src/core/session-manager.ts`: parent-linked entries, active position,
  traversal, and compaction-aware context reconstruction.
- `src/core/agent-session.ts`: `navigateTree`, summary preparation, and events.
- `src/modes/interactive/interactive-mode.ts`: `showTreeSelector` and editor flow.
- `src/modes/interactive/components/tree-selector.ts`: navigation UI.
- `test/agent-session-tree-navigation.test.ts`, `test/tree-selector.test.ts`,
  and `test/session-manager/tree-traversal.test.ts`: useful behavioral references.

Copy the user-facing concepts, not Pi's storage format or durability assumptions.
Tackle retains explicit sync barriers, required-event validation, and honest
external-effect recovery.

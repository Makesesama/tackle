# Tackle session persistence, recovery, and search architecture

Status: accepted architecture; core implemented. The root harness now stores one
append-only internal `:disk_log` journal per session with a single supervised
writer, explicit `sync/1` barriers, validated replay with visible repair, fresh
runtime reconstruction on resume with an explicit interruption-recovery gate, a
rebuildable ETS/search catalog, self-contained forks, archiving, trash-first
deletion, and zstd compression of idle journals. Replay checkpoints, schema
migration, cross-host writer fencing, durable scripted-workflow state,
encryption, compressed commits, retention policy, and protocol export/import
remain unimplemented; this document is the accepted target for them, and
passages describing them are labelled as planned. The `Tackle.*` operations
listed in section 11 are the implemented subset unless a passage explicitly
labels them as deferred.

Scope: saving and loading agent conversations, crash recovery after process or BEAM shutdown, local session discovery and search, schema evolution, and session forks. Durable scripted-workflow state, distributed storage, and transparent reconstruction of the in-memory runtime process tree remain out of scope.

This document resolves the session-persistence decisions deferred by [`RUNTIME_ARCHITECTURE.md`](RUNTIME_ARCHITECTURE.md). It preserves that document's runtime boundaries: `Tackle.Lib` remains the provider-neutral loop, the root Tackle harness owns persistence and orchestration, and runtime references remain distinct from durable conversation identity.

## 1. Agreed direction

1. Tackle uses one append-only journal as the canonical durable source of truth for each persisted agent session.
2. The journal uses Erlang/OTP's `:disk_log` in `:internal`, `:halt` mode. Tackle does not define a second framing layer or add a persistence dependency for the initial implementation.
3. The internal `:disk_log` file is trusted, Tackle-owned local state. It is not an interchange format and is never opened directly from an untrusted import.
4. Each logged item is one self-contained, versioned Tackle commit. A commit contains one or more related domain events and one monotonic session sequence number.
5. `%Tackle.Lib.State{}` is not serialized. The durable schema contains only deliberate conversation data and audit metadata represented as plain values.
6. Saving is continuous. There is no ordinary user-visible “save the current struct” operation. Explicit flushing exists only as a durability barrier.
7. Tackle calls `:disk_log.sync/1` before a tool with external effects runs. Turn boundaries, messages, and tool intents are appended write-behind: they reach the OS within about two seconds (surviving an application crash) and become durable at the next sync. Power loss can lose the last turns; that trade is deliberate (section 9).
8. One supervised journal owner serializes every write to one session. A session journal has at most one writable owner.
9. A journal failure is fatal to further durable execution of that session. Tackle fails closed rather than continuing with memory-only state after persistence has failed.
10. Loading replays durable conversation data into a fresh, trusted runtime configuration. It never restores PIDs, Tasks, runtime references, credential handles, executable modules, or stale process state.
11. Search, summaries, checkpoints, and indexes are derived projections. They may lag, be deleted, or be rebuilt without changing the durable session.
12. Streaming token deltas and frontend-only events are not canonical history. Tackle persists settled messages, turn boundaries, tool-execution boundaries, configuration changes, and terminal outcomes.
13. The CLI's root conversations are durable by default. Delegated agents (the runtime's `:ephemeral` lifetime) keep their conversation in memory only unless a later explicit retention policy gives them independent durable sessions.
14. A fork creates a new, self-contained journal. A child session records its lineage but does not depend on the parent file remaining available.
15. Session files remain local to one Tackle storage root. Distributed authority, replication, and concurrent multi-node writers are deferred.

## 2. Why `:disk_log`

Tackle is intended to be an OTP-native harness that is small without omitting important behavior. `:disk_log` already provides the difficult low-level mechanics needed by this design:

- one OTP process serializes requests to an open log;
- synchronous and asynchronous append APIs;
- an explicit `sync/1` durability operation;
- binary term framing;
- efficient chunked replay;
- internal write buffering;
- detection and repair of uncleanly closed internal logs;
- owner linking and notification;
- halt, wrap, and rotation policies; and
- no dependency outside OTP.

Tackle uses only the parts that fit canonical conversation history:

```text
format = internal
type   = halt
mode   = read_write for the one owner
size   = infinity initially
```

A wrap log is not acceptable as canonical history because it overwrites old items. Rotate logs are external-format operational logs rather than complete replayable histories. An optional application-level retention or compaction policy must create a new validated journal instead of allowing `:disk_log` to overwrite old commits.

`:disk_log` is a stable OTP API, but its internal file format is deliberately opaque and readable only through `:disk_log`. Tackle therefore owns the file and supplies separate inspection and export APIs.

### 2.1 Why not RFC 7464 for the canonical journal

RFC 7464 JSON Text Sequences is a sound standardized framing format, and mature general tools support it:

- `jq --seq`;
- `journalctl -o json-seq`;
- small Go, Python, and Node encoders and decoders; and
- the registered `application/json-seq` media type.

Research found no meaningful adoption of RFC 7464 framing in current agent persistence or agent protocols. Pi and grok-build use JSONL; provider streaming generally uses SSE; MCP uses newline-delimited JSON-RPC over stdio and JSON or SSE over HTTP; OpenTelemetry's file exporter specifies JSON Lines; and surveyed agent frameworks use databases, checkpoint stores, ordinary JSON, or JSONL. No relevant maintained Elixir package was found.

Consequently, RFC 7464 would provide general portability but no demonstrated compatibility with agent-session tooling. That does not justify reimplementing writer serialization, framing, buffering, syncing, and repair already supplied by OTP. If a real RFC 7464 consumer appears, it can be an export format without changing the journal.

### 2.2 Why not raw ETF

The External Term Format is a serialization format, not an append-log protocol. Concatenating ETF values directly would still require Tackle to define and test:

- item boundaries;
- maximum item sizes;
- torn-tail recovery;
- corruption detection;
- serialized ownership;
- flushing and syncing; and
- format migration.

`:disk_log` internal format supplies that container around ETF terms. The canonical file should therefore use an extension such as `session.dlog`, not `.etf`: it is a `:disk_log` container containing versioned Tackle terms, not one raw external term.

## 3. Terminology and identity

### 3.1 Durable session

A durable session is one persisted agent conversation. Its stable identity is `Tackle.Lib.State.session_id`.

The same durable session can be loaded into several runtime scopes over time, but never by more than one writable owner at once. Every load receives new runtime identities and processes.

### 3.2 Runtime scope and agent

A runtime scope is the in-memory supervision and cancellation boundary defined by [`RUNTIME_ARCHITECTURE.md`](RUNTIME_ARCHITECTURE.md). Values such as `ScopeRef`, `AgentRef`, script IDs, PIDs, monitors, Tasks, cancellation signals, and request helpers are ephemeral.

The identity relationship is:

```text
stable session_id
  ├── runtime scope A and root AgentRef A   first execution
  ├── runtime scope B and root AgentRef B   later resume
  └── runtime scope C and root AgentRef C   later resume
```

A durable session does not encode fleet membership or runtime parentage. A resumed conversation starts a new in-memory scope.

### 3.3 Journal, projection, and checkpoint

- **Journal:** the authoritative append-only `:disk_log` file.
- **Projection:** state obtained by folding validated journal commits.
- **Runtime state:** fresh `%Tackle.Lib.State{}` and trusted executable configuration built from a projection.
- **Checkpoint (planned):** a disposable projection snapshot used to accelerate replay (section 13).
- **Catalog:** a rebuildable index used to list and search sessions.

The word “WAL” can describe the write-before-effect discipline, but “session journal” is more precise. The journal is itself the durable history; there is no second durable conversation file updated in place.

## 4. Relationship to the current runtime

The current runtime keeps one settled `%Tackle.Lib.State{}` in each `Tackle.Session` and runs one active turn in a supervised Task. That remains the in-memory ownership model.

A durable root scope adds one critical journal owner:

```text
Tackle.Runtime.Supervisor
├── Tackle.Runtime.Registry
└── Tackle.AgentSupervisor
    └── AgentScope
        ├── WorkSupervisor
        ├── ScopeCoordinator
        └── Runtime.AgentSupervisor
            ├── Task.Supervisor             root tool execution
            └── Session.RuntimeRootSupervisor
                ├── Tackle.Session.Journal  one writable owner
                └── Root Tackle.Session

Tackle.Supervisor
├── Tackle.Auth.Store
├── Tackle.Session.JournalRegistry
└── Tackle.Session.Catalog                 derived search/list projection
```

Each journal owner starts its own deadline process (`Tackle.Session.Journal.Deadline`)
outside the supervision tree; the two monitor each other, so neither outlives the
other (section 9).

The exact child ordering may change, but these behaviors are required:

- the journal owner is available before the root session accepts work, and a new session is materialized before its first turn Task starts;
- the root session and its internal persistence hook can make synchronous journal calls;
- a journal-owner failure prevents further execution and terminates the durable scope;
- orderly scope shutdown syncs and closes the journal, and the supervisor waits
  for the journal's cleanup deadline (`journal_timeout`) before killing it;
- a scope started without a `Tackle.Session.Spec` has no journal at all; and
- one journal process never becomes a global bottleneck across unrelated sessions.

A dedicated journal owner is justified even though `:disk_log` has its own process. The Tackle owner holds the application sequence, validates commits, applies durability policy, owns the `:disk_log` lifecycle, and provides one narrow API to the session and loop hook. Callers do not open or write the file directly.

## 5. Storage layout

The local layout is rooted under `TACKLE_HOME` (`Tackle.Session.Storage`):

```text
$TACKLE_HOME/
└── sessions/
    ├── catalog/                         compression.marker: the last compression pass
    ├── trash/                           recoverable deletions, <session-id>-<ms>
    ├── archive/                         archived sessions, same layout as below
    ├── <session-id>/                    legacy flat session (no project)
    └── --home-user-project--/           path-derived project directory
        └── <session-id>/
            ├── session.dlog             canonical journal
            ├── session.dlog.zst         the journal, compressed once idle
            ├── session.dlog.read-*      temporary decompressed copies for readers
            ├── summary.etf              optional derived summary sidecar
            ├── writer.lock              one-writer lock (section 6.1)
            ├── journal-failure.json     payload-free report of a failed owner
            ├── checkpoint.etf           planned, not written: replay checkpoint (section 13)
            └── recovery/                copies preserved before repair (*.bak, *.bak.zst)
```

The catalog's index is held in memory and rebuilt at startup; `catalog/` holds
no index. A journal idle for a week is replaced by a verified zstd copy of its
exact bytes, `session.dlog.zst` (`Tackle.compress_idle_sessions/1`). Readers
replay it from a private temporary copy beside it, a writable owner restores
the plain journal under the writer lock before opening it, and when both forms
exist the plain journal is authoritative.

Session IDs are used as opaque path components after validation. Project paths are expanded to absolute paths and encoded by escaping literal
`-` as `-2D`, replacing `/` with `-`, then wrapping in `--`. The catalog scans project directories and legacy flat sessions;
read/write operations address a project session with the same `:cwd` used at
creation. Existing flat sessions are not migrated automatically. If directory fan-out becomes a measured problem, the implementation may add deterministic sharding without changing session identity or the journal schema.

The journal is the only required durable file. `summary.etf`, a future `checkpoint.etf`, and the catalog can always be removed and recreated.

The directories under `sessions/`, `sessions/` itself and the project directories included, are private to the current user (`0700`), and the journal, its compressed and temporary copies, its sidecars, the writer lock, failure reports, and recovery copies are `0600`. Directories and journals an earlier version created with default modes are tightened when the session is next opened for writing. Filesystem permissions are part of the security boundary because the journal holds whole conversations and internal repair and ordinary `:disk_log.chunk/2` can decode ETF terms.

## 6. Journal ownership and opening

A journal owner opens the log with values equivalent to:

```elixir
:disk_log.open(
  name: {:tackle_session, session_id},
  file: String.to_charlist(path),
  type: :halt,
  format: :internal,
  mode: :read_write,
  repair: repair?,
  notify: true,
  size: :infinity
)
```

The name is a tuple containing the binary session ID. Tackle must not create one atom per session.

`Tackle.Session.Reader` opens every `:disk_log` handle of a journal with these options (read-only replay with `mode: :read_only`, `repair: false`, and no notifications) and names every log (`Reader.name/1` is the writable one). Only the journal-owner process opens a session's log for writing and calls `log/2`, `sync/1`, or `close/1` on it; other runtime processes use the owner's API, read-only replay opens the file under a name of its own, and a fork writes its unpublished child with `Reader.write_journal/2`. Notifications including `error_status`, `full`, `truncated`, and unexpected wrap events are handled explicitly.

### 6.1 One-writer invariant

OTP serializes callers using the same open log on one node, but it does not prevent the same file from being opened under another name, in another BEAM, or on another node. OTP documents that concurrent writable opens can corrupt the file.

The initial storage contract is therefore:

```text
one TACKLE_HOME
  → one writable Tackle application at a time per session
  → one journal owner
  → one :disk_log process
```

A deterministic log name protects against duplicate opens within one connected node. A storage ownership guard rejects concurrently active writers when detectable. Cross-host failover and distributed leases are not promised. If ownership is uncertain, Tackle fails with `{:session_in_use, owner}` or `{:repair_required, path}` rather than opening with automatic repair; repair happens only when the session's spec allows it (`repair: true`, which the CLI sets when it resumes a session).

The guard is `writer.lock` in the session directory (`Tackle.Session.Storage.Lock`). On systems with `flock`, it is an operating-system advisory lock, so it holds across BEAMs and PID namespaces on one host: a port running `flock`, linked to the journal owner, holds it until it is released or the owner dies. Elsewhere the file's owner record is the lock, and a record whose process is gone is reclaimed. Either way the file records its owner (OS pid, node, start time, and process identity where available) as JSON, which a conflict reports as `{:session_in_use, owner}`. A conflict with this same OS process (background compression, or moving a session to the archive or trash) is retried for up to two seconds; a lock attempt that fails leaves nothing behind for its caller, so the waiting journal owner keeps running.

Losing the lock is fatal: the owner then only closes its log, and neither syncs, writes the summary sidecar, nor releases a lock in a directory another process may own now.

Opening an *existing* journal takes its lock without creating the session directory, and checks under the lock that the journal still exists. A session moved to the archive or the trash (which happens under its lock) while a resume was waiting is reported as `{:session_not_found, session_id}` instead of being recreated as an empty session with the same id.

### 6.2 Deferred materialization of new sessions

The journal owner process starts with its durable scope, so scope supervision and fail-closed behavior are unchanged. A *new* session is not materialized until its first prompt, however. Until then the owner holds the validated session id, storage options, and creation metadata in memory and writes nothing:

- no session directory, ownership lock, `session.dlog`, or `session.created` commit exists;
- the catalog has no entry, so opening and quitting the CLI creates no visible session;
- an idle reconfiguration or metadata change only updates the metadata that the eventual `session.created` commit will record;
- `Tackle.Session.Journal.projection/1` reports a provisional, empty projection so the frontend can resolve configuration exactly as it would for a materialized session;
- enabling branching only sets the `tree` flag the eventual `session.created` records; and
- flushing, awaiting, or stopping an unmaterialized journal is a no-op.

The first `turn.started` commit materializes the session: the owner acquires the lock, opens the internal halt log, writes the header and `session.created`, and then appends `turn.started` before the turn Task starts. This preserves the rule that the journal is available before the session accepts durable work while avoiding empty sessions. An *existing* journal is still opened, validated, and — when repair is requested — repaired eagerly at scope start, so resume never fabricates history.

## 7. Durable record schema

### 7.1 Plain-data rule

Every journal item is composed only from a constrained durable data model:

- UTF-8 binaries;
- byte binaries with explicit meaning;
- integers and finite floats;
- booleans and `nil`;
- lists; and
- plain maps with known keys.

The durable codec rejects:

- PIDs, ports, references, and functions;
- Tasks, monitors, cancellation signals, and Registry values;
- executable module identities as data-selected behavior;
- arbitrary structs;
- runtime handles;
- credential-store handles and credential-shaped options; and
- recursive or oversized terms outside configured limits.

Dates and times are stored as RFC 3339 UTC strings. Event kinds and extensible names are binaries rather than dynamically created atoms.

### 7.2 Header

The first logical item identifies the file and its durable session:

```elixir
%{
  "record" => "tackle.session.header",
  "format_version" => 1,
  "session_id" => session_id,
  "created_at" => "2026-09-10T11:00:00Z",
  "cwd" => "/path/to/project",
  "parent" => nil
}
```

A forked session uses a parent value such as:

```elixir
%{
  "session_id" => parent_session_id,
  "seq" => parent_seq
}
```

The journal writes the header as the log's first item (not through `:disk_log`'s `head` option), and the synced `session.created` commit makes it durable. Replay treats it as sequence zero. It is immutable after creation; changes such as title, tags, or current working directory are later events.

### 7.3 Commit envelope

Every subsequent item is one complete logical commit:

```elixir
%{
  "record" => "tackle.session.commit",
  "schema_version" => 1,
  "session_id" => session_id,
  "seq" => 17,
  "commit_id" => commit_id,
  "written_at" => "2026-09-10T11:05:00Z",
  "turn_id" => turn_id,
  "events" => [
    %{
      "type" => "message.appended",
      "version" => 1,
      "required" => true,
      "data" => message_data
    }
  ]
}
```

The complete commit is passed to one `:disk_log.log/2` call. Several separate `log/2` calls are never described as one transaction. `log_terms/2` may be an efficient batch operation, but it does not define Tackle's logical atomicity.

Required envelope rules include:

- `session_id` matches the header;
- `seq` is exactly the previous sequence plus one;
- `commit_id` is a binary (each commit gets a freshly generated id; replay
  does not check that ids are unique) and `written_at` a timestamp string;
- `events` is a non-empty list;
- each event has an independently versioned schema, and its `data` is a map;
- every value passes the durable-data validator;
- the commit folds into the current projection: no duplicate entry id, a known
  parent and navigation target, a decodable compaction; and
- each event's data remains below an application-defined maximum size (24 MB) substantially lower than `:disk_log`'s 4 GB term limit.

The journal owner builds envelopes and events itself (`Tackle.Session.Log`'s builders), so their identity, sequence, and versions hold by construction; before appending it checks once that each event's data passes the durable-data validator and that the commit folds. Replay checks every rule.

Unknown required events stop replay with `{:unsupported_required_event, type, version}`. Unknown optional extension events are retained in the replayed commits while the core projection ignores them.

The live owner checks these rules, folding the commit into its projection, before it appends anything, so a commit replay would reject never reaches the file. A refused write (invalid data, a commit that would not fold, a branch in a session without branching, a write without an active turn, a settlement of another turn) returns `{:error, reason}` and leaves the journal usable. A failure once bytes may have been written (append, sync, lost lock, a `:disk_log` error notification) stops the owner and its durable scope.

### 7.4 Event types

The initial durable event algebra includes:

```text
session.created
session.metadata_changed
session.configuration_changed
session.recovered
session.closed               legacy: replayed for its closed_at, no longer written
session.forked
turn.started
message.appended
context.compacted
tree.enabled                 a linear session may branch from now on
tree.navigated               a committed change of the active position
tool.execution_started
turn.completed
turn.errored
turn.cancelled
turn.crashed
turn.abandoned
```

Every event is at version 1. `Tackle.Session.Log` builds each one the journal
writes (`Log.turn_started/4`, `Log.message_appended/2`, and so on).

Events record semantic facts, not internal function calls. Provider-specific continuation state remains inside the serialized message only when it satisfies the existing non-secret provider-state contract and the durable-data validator.

A durable message projection includes the relevant fields from `Tackle.Lib.Message`:

- message ID;
- role;
- content;
- thinking or reasoning state when required for continuation;
- normalized tool calls and tool results;
- timestamp;
- normalized usage;
- selected model; and
- validated provider continuation state.

Tool definitions, adapters, and hook modules are not stored as executable terms. Audit events may store model references and tool names.

### 7.5 `context.compacted`

`context.compacted` is version 1 and records one durable compaction of the
provider-visible model surface. It never rewrites the append-only transcript; it
only says which synthetic checkpoint now leads the model projection and which
transcript ids it shadows:

```text
compaction_id              # also the synthetic checkpoint message id
trigger                    # pressure | overflow | manual
summary_message            # the encoded synthetic checkpoint message
shadowed_message_ids       # provenance, in transcript order
first_retained_message_id  # nil when no tail exists
previous_compaction_id     # optional audit chain link
tokens_before
estimated_tokens_after
summary_usage              # auxiliary summarizer usage
summary_model
created_at
details                    # bounded plain-data extension field
```

The event is committed and synced before the in-memory replacement is installed.
Replay folds `message.appended` into both `Projection.messages` (the canonical
transcript) and `Projection.model_messages` (the provider surface), while
`context.compacted` replaces only the model-surface prefix with the checkpoint.
Search, previews, and message counts continue to read the transcript.

## 8. Turn persistence protocol

Saving is integrated at semantic boundaries using the root session and an internal root-harness hook. It must not require provider-specific logic in `Tackle.Lib`.

### 8.1 Starting a submitted turn

For `submit`:

1. `Tackle.Session` asks the journal, from a storage task, to append `turn.started` (write-behind), including the raw submitted input for audit and recovery diagnostics, followed by the messages the turn takes from the session's inbox. For a new session this first commit also materializes the journal: the owner acquires ownership, opens the log, and writes and syncs the header and `session.created` first.
2. Only after the appends succeed does the session start the supervised turn Task.
3. `Tackle.Lib.Loop` constructs and settles the user message.
4. The internal `after_message` hook appends `message.appended` write-behind. It becomes durable at the next sync (an external tool's gate, a synced commit such as a compaction or title, or an explicit flush); the provider request only waits until the journal has finished earlier requests, without syncing.
5. If persistence fails, the hook aborts the turn and the session does not continue in memory-only mode.

The settled user message, rather than the raw input in `turn.started`, is the conversation projection. A crash before that message commits leaves an interrupted attempt but does not fabricate a message during replay.

### 8.2 Continuing without a new message

For `continue`:

1. the session appends `turn.started` (write-behind) with operation `continue`;
2. the Task starts only after the commit succeeds; and
3. the loop proceeds using the existing durable conversation.

### 8.3 Assistant messages and tools

The existing hook lifecycle provides the required boundaries:

- `after_message` appends a settled assistant or tool message;
- `before_tool_call` appends `tool.execution_started`, and the loop's `:before_tool_execution` gate syncs every intent of the step (and the assistant message before it) before a tool with external effects is invoked. Tools that declare `effect/0 :: :read_only` (`read`, `load_skill`) skip the gate; and
- a settled tool-result message is appended write-behind and becomes durable at the next sync point.

This creates an honest recovery distinction:

```text
tool.execution_started with a later tool message
  → tool result is known and replayable

tool.execution_started without a later tool message
  → tool may have produced an external effect; outcome is uncertain
```

Tackle must never automatically repeat an uncertain tool execution merely because its result is absent.

Library streaming events can reach a live subscriber before the persistence hook completes. They remain observational. The durability guarantee is that tool intent is committed before a tool with external effects runs. Terminal completion is announced once the terminal event is appended, not synced. Power loss can lose the unsynced tail: settled messages, tool results, and whole recent turns since the last sync. Replay then sees a consistent prefix; an external tool whose result was lost appears as an uncertain `tool.execution_started`, and the provider calls of the interrupted turn are simply made again on retry.

### 8.4 Terminal settlement

After the turn Task settles or crashes, `Tackle.Session` appends the corresponding terminal event (write-behind, not synced) before:

- replacing the session's settled in-memory state;
- broadcasting `:tackle_turn_finished` or `:tackle_turn_failed`;
- delivering a delegated (`:ephemeral`) session's correlated outcome; or
- accepting another turn.

Expected outcomes remain distinct:

```text
turn.completed
turn.errored
turn.cancelled
turn.crashed
```

A Task crash is never rewritten as a normal library error.

A terminal event settles the active turn, or the interrupted turn a resumed
journal reports, and must name it: settling another turn, or one turn twice, is
refused with `:turn_mismatch`.

When the journal refuses a message the loop settled (it cannot be recorded),
the persistence hook fails the turn with `{:message_not_journaled, reason}`.
The turn's state still holds that message, so after `turn.errored` is
appended the session rebuilds its state from the journal like after a crash;
the journal itself stays usable.

A crashed Task returns no state, but the persistence hook has already
journaled the messages it settled. After `turn.crashed` is appended, a durable
session therefore rebuilds its state from the journal's projection the way it
does on resume (the persistence hook and committer installed, unresolved tool
calls repaired), so the next turn continues the journaled conversation. A
session without a journal keeps its pre-turn state, since nothing was written.

A turn whose start fails after `turn.started` is appended (its queued
messages cannot be journaled, or its Task cannot be started) is settled the
same way, with `turn.crashed`, before the session goes idle: the caller of
`submit/2` or `continue/1` then gets the error, and a turn the session
started from its inbox is reported with `:tackle_turn_failed`. If that
terminal append fails, the session stops like after any other persistence
failure. Queued messages leave the inbox only once they are journaled, or,
without a journal, once the turn's Task runs.

### 8.5 Reconfiguration

An idle model or thinking-level change is persisted before it becomes the accepted session configuration. `session.configuration_changed` stores only the durable selection, `model_ref` and `thinking`, with `changed_at`; never executable adapter modules, adapter options, or credentials.

It records the normalized thinking level (`"off"` when none is set, or for a
provider-specific value a host set directly), the same value `session.created`
records; journals of earlier versions that recorded the raw option, `nil` when
unset, still load. The commit is synced. If it fails, `Tackle.Session.reconfigure/2` returns the error and the session stops, as after any other journal failure; it never continues with a configuration the journal did not record.

### 8.6 Stopping

A session has no close operation of its own: hosts stop its scope (`Tackle.stop_scope/1`). The session process cancels and shuts down an active turn's Task without writing a terminal event, so the turn resumes as interrupted. The journal owner then performs:

1. `:disk_log.sync/1`;
2. `:disk_log.close/1`;
3. writing the session's summary sidecar and recording the final summary in the catalog; and
4. release of journal ownership.

After a lost writer lock it only closes the log and records the final summary in the catalog (section 6.1).

Both carry the status replay reports (`Tackle.Session.Projection`'s `status`, which every commit keeps current): `:interrupted` for a turn that was still running, never the `:active` the catalog lists while the owner runs a turn.

The runtime appends no `session.closed` commit; journals that already contain one still replay, and the projection reports its `closed_at` without classifying the session as closed, so a later turn resumes it like any other. A process or BEAM crash can skip these steps. Recovery must therefore rely on journal repair and replay, not on the presence of `session.closed`.

## 9. Durability contract

`:disk_log.log/2` is synchronous with the log process but does not guarantee stable storage. OTP internally buffers writes and the operating system may buffer them again. The initial implementation therefore has one simple durability policy:

```text
semantic commit
  → :disk_log.log/2
  → :disk_log.sync/1
  → acknowledge success
```

There is no user-configurable buffered durability mode. `session.created`, compaction, navigation, `tree.enabled`, configuration, metadata, and recovery commits follow the policy above. `turn.started`, terminal events, and loop-written messages and tool intents are write-behind, as described next.

### Write-behind loop commits

Messages and tool intents written by the loop's persistence hook are appended
write-behind: validated, sequenced, and passed to `:disk_log.log/2` in order,
without a sync. `turn.started` and the terminal event are appended the same
way. Because the log is ordered, one sync makes every earlier commit durable.
The session syncs only where an irreversible effect depends on it:

```text
:before_tool_execution gate       Journal.await_durable/1 before external tools run
:before_provider_call gate        Journal.await_idle/1: waits behind a busy or
                                  stalled journal, never syncs
turn.started, terminal event      appended, not synced
```

Unsynced commits are not only in memory. `:disk_log` writes its cache to the
file within about two seconds (or at 64 KB), after which the OS holds them and
writes them back on its own schedule (ext4 commits every few seconds), so an
application or VM crash keeps them. Only power loss or a kernel crash can lose
that tail, and losing the last turns is acceptable: they are cheap to redo, and
no external tool has run on unsynced facts. A turn that completed without any
external tool is therefore never synced on its own. Readers of a live
session's file (`inspect_session`, fork) flush the journal first. Orderly close
syncs before releasing the file.

A provider call needs no durable record first: after a crash the turn is
interrupted and retrying it only repeats provider calls. It still waits behind
the journal so the loop does not run ahead of stalled or failed storage.
Read-only tools (`Tackle.Lib.Tool.effect/1`) skip the tool gate, because
running them again after a crash changes nothing.

What a crash can lose is the unsynced tail. Because the log is ordered, a
durable tool result implies its durable intent, and a durable intent implies
the assistant message that requested it, so replay always sees a consistent
prefix. Under the harness's concurrent tool policy a step with external tools
costs one sync for all of its intents (the sequential policy runs the gate per
external call). This keeps disk wear low: each sync rewrites the log's tail
block and forces a filesystem journal commit. `await_durable/1` does not touch
the disk when nothing is unsynced; `Journal.flush/1` stays an explicit barrier
that always syncs. The derived catalog is refreshed when a sync makes new
commits durable, not on every append.

`sync/1` is the strongest durability operation provided by OTP, not a promise that every filesystem, device controller, or virtualized disk honors physical persistence perfectly. Tackle reports its guarantee as successful completion of the OTP/file sync boundary.

The implementation must propagate full-disk, permission, device, sync, and log-process failures. It must never suppress them to preserve apparent agent progress.

### Slow live storage: pause and recover

The journal's deadline process treats its default 15-second deadline as a soft threshold
only for the stages in which a live request waits for the disk: appending
(`:append`, and `:append_header` when a new session is materialized) and
`:sync`. `:disk_log.log/2` is a call to the log's process, which writes its
64 KiB cache with a blocking `write(2)` when the cache fills or its two-second
timer fires, so under writeback pressure an append waits as long as a sync;
since commits are written behind (§8), most commits never sync, and a slow disk
shows up in the append. The journal keeps the original request in flight and
the pending commit ID/sequence unchanged; it never re-appends or issues a second
sync on expiry, and it logs a payload-free warning. Durability hooks and queued
writes remain behind that barrier. A successful reply resumes progress
automatically. Storage errors, stalls outside the disk waits (validation,
projection, the post-write catalog update, an owner that stops responding),
startup/replay, and cleanup remain fail-closed with hard bounds and explicit
crash recovery. Work after a paused wait gets a fresh hard deadline.

Session-side durability waits run in supervised tasks with correlated
continuations, leaving snapshots and cancellation responsive. A session
broadcasts `{:tackle_storage, session_id, :delayed | :ready}` and exposes that
status in its snapshot. While delayed it rejects new mutating admission with
`:storage_busy`; input for an active turn (a submit or an agent message) is
still queued, also while the turn's begin or terminal event is being written,
because queueing writes nothing. One-shot runtime launch/completion notices remain admitted to
the bounded inbox (128 deferred notices, 32 ordinary messages, 24 MiB total
encoded entries); their continuation waits for storage readiness. The journal serializes dispatch and retains at most 64 queued
requests / 24 MiB of encoded request data, returning `:journal_busy` at capacity.
The CLI shows “Waiting for session storage”; its one-shot answer timeout does
not expire during that wait. Cancellation requests are accepted, but terminal
settlement still waits for the journal, since the terminal event queues behind
the stalled write. Already-running parallel effects are
not rolled back.

### 9.1 Compaction durability barrier

Checkpoint compaction is the one session operation that changes the
provider-visible projection rather than appending to it. It preserves the same
fail-closed contract:

1. `Tackle.Lib.Compaction` selects a balanced plan without mutation;
2. it generates and strictly validates the summary (non-empty, complete, no tool
   calls, strictly smaller than the shadowed region, and for pressure
   compaction low enough to land below the threshold);
3. it builds the replacement without installing it, appending the compaction
   entry to a copy of the conversation tree, so a record the tree refuses is
   never committed;
4. it commits one `context.compacted` event through the state's
   `Tackle.Lib.Committer`, `Tackle.Session.Committer`, which resolves the live
   journal by session id and syncs the commit (the record names the tree entry
   it attaches to, written as `parent_id` in a branching session and left out,
   as implied, in one without branching);
5. only after a successful commit does it install the replacement in
   `State.model_messages`.

A summarizer, validation, or commit failure leaves the model context unchanged. A
commit failure is returned as `{:error, {:durable_commit_failed, reason}, state}`
so the loop fails the turn instead of continuing with an unpersisted checkpoint. The
canonical transcript is never compacted, so history remains append-only,
inspectable, searchable, and forkable.

## 10. Loading, replay, and runtime reconstruction

### 10.1 Replay

A reader folds records in sequence order:

1. read the internal items in chunks of 100 with `:disk_log.bchunk/3`, which returns encoded item binaries, and decode each with `:erlang.binary_to_term(binary, [:safe])` (the whole history is then folded in memory);
2. validate the header and its supported format version;
3. validate one durable commit envelope at a time, requiring contiguous sequence numbers;
4. upcast known older event versions in memory, then validate each event against its current version (`Tackle.Session.Log.read_commit/4`);
5. apply events to a plain durable projection, which rejects a commit it cannot fold consistently; and
6. report the status the projection keeps current: clean, interrupted, or recovered. A journal that fails validation (corrupt) or uses a newer version (unsupported) is an error rather than a status.

`:safe` decoding prevents creation of new atoms and new external function references during ordinary replay. Durable validation is still required after decoding; `:safe` protects the VM from specific ETF hazards, not the application from malicious or nonsensical values.

### 10.2 Repair

Internal `:disk_log` can repair an uncleanly closed log, but repair is not treated as silent success.

The recovery path is:

1. establish exclusive application ownership (the writer lock);
2. open the log with `repair: false`; when `:disk_log` reports that it was not closed cleanly, fail with `{:repair_required, path}` unless the session's spec allows repair;
3. preserve the original unclean file under `recovery/` before repair;
4. reopen the log with internal repair;
5. record the returned recovered-item and bad-byte counts;
6. replay every recovered commit through normal schema and sequence validation; and
7. append and sync `session.recovered` only after validation succeeds.

A repaired session is visibly marked as recovered (status `:recovered` once no turn is interrupted), whether or not bytes were lost. If replay of the repaired log finds a gap, an invalid envelope or event, an unsupported version or required event, or a commit that does not fold into the projection, the owner refuses to open it (`{:repaired_history_invalid, reason}`) and the original stays under `recovery/`. Tackle does not silently skip a complete invalid commit. A log that was closed cleanly but has damaged bytes is not a crash's torn tail and is not repaired.

Read-only replay never repairs. It reads a journal that was not closed cleanly as it is: an intact one replays normally, and one with a torn tail or damaged bytes returns `{:journal_bad_bytes, count}` until a writable owner repairs it.

`:disk_log` internal repair uses ETF decoding internally. Therefore repair is allowed only for the private trusted storage root. Imported or attacker-controlled files must never enter this path.

### 10.3 Incomplete turns

A `turn.started` event without a matching terminal event makes the session interrupted. Replay also identifies tool starts without durable results: a tool result resolves the start with its tool call id in whichever turn it arrives, so the results a repair turn writes for an earlier turn's calls resolve them. `Tackle.Session.Projection.uncertain_tools/1` is the one definition; inspection and the recovery a resumed session reports both use it.

`Tackle.inspect_session/2` reports the projection's `status` (`:interrupted`), `last_seq`, and `uncertain_tools`; a resumed session reports the recovery its frontend must decide in its snapshot (`Tackle.Session.Snapshot.recovery`):

```elixir
%{
  turn_id: turn_id,
  operation: "run",
  uncertain_tools: [...]
}
```

Opening the session read-only always remains possible when replay validates. Writable resume appends a recovery decision such as `turn.abandoned` before accepting new work.

If unresolved tools may have produced side effects, automatic continuation is prohibited. The frontend must let the user inspect the uncertainty and explicitly abandon, repair, or otherwise resolve it.

### 10.4 Reconstructing `Tackle.Lib.State`

Replay does not deserialize a state struct. It produces a durable projection containing messages, metadata, selections, lineage, and recovery status.

Runtime reconstruction then:

1. loads current trusted `Tackle.Config` and credentials;
2. resolves the recorded selection, the pair of model and thinking level the
   journal last recorded (a recorded `nil` level means none was set), or an
   explicit user override; `Tackle.Session.Loader.load/3` returns the
   resolved configuration, which the session keeps for later
   reconfiguration and title generation;
3. creates a fresh `%Tackle.Lib.State{}` from that configuration (tools,
   hooks, and context come from it, never from the journal), passing the
   durable session ID as `:session_id` instead of generating one;
4. installs the projection's replayed `Tackle.Lib.Tree` with
   `Tackle.Lib.State.put_tree/2`, which derives the active transcript
   (`State.messages`) and the provider context (`State.model_messages`) from
   it, for sessions with and without branching alike;
5. resets the per-turn fields (iteration count, status, error, and error
   reason) with `Tackle.Lib.State.reset_turn/1`;
6. attaches fresh runtime handles and cancellation state; and
7. records a durable configuration change if the user selected a different model or thinking level.

`Tackle.Session.Durable.open/3` runs these steps when a session starts,
reading the journal's projection once: it also enables branching when the
session spec asks for it, installs the persistence hook and the committer,
reports an interrupted turn as the recovery the frontend must decide, and
otherwise repairs tool calls a settled turn left without results. After a
turn whose start failed, whose task crashed, or whose message the journal
refused is settled, `Durable.reopen/4` rebuilds the state the same way, with
the session's configuration overriding the recorded one.

If the recorded configuration cannot be resolved, loading returns a typed configuration-required result. It does not silently switch providers or models.

## 11. Load, resume, and inspect semantics

Internally, one replay operation supplies several public use cases:

- **inspect:** read and project a session without creating an agent scope;
- **load:** create a runtime and replay history to an attaching frontend;
- **resume:** create a runtime from the same durable projection without requiring the frontend to receive historical events again; and
- **fork:** materialize a new durable session from a selected validated sequence.

This distinction aligns with the Agent Client Protocol's session concepts: ACP `session/load` replays history to the client, whereas `session/resume` restores the agent-side session without replaying that history. ACP does not define Tackle's local storage format.

The implemented operations are:

```elixir
Tackle.inspect_session(session_id, opts)
Tackle.session_usage_timeline(session_id, opts)
Tackle.all_usage_timeline(opts)
Tackle.list_sessions(filters)
Tackle.search_sessions(query, filters)
Tackle.session_summary(session_id, opts)
Tackle.fork_session(session_id, opts)
Tackle.archive_session(session_id, opts)
Tackle.unarchive_session(session_id, opts)
Tackle.delete_session(session_id, opts)
Tackle.flush_session(session_id)
Tackle.compress_idle_sessions(opts)
```

Creating and resuming have no functions of their own: a host starts a scope (`Tackle.start_scope/1`) with a `Tackle.Session.Spec`. A spec without a `session_id`, or with an id no journal has, creates a session; one with an existing session's id resumes it. **load** (replaying history to an attaching frontend) is deferred; a frontend reads the resumed snapshot's `agent_state` instead.

These operations return stable session metadata and PID-free runtime references. They never expose the journal process or `:disk_log` name.

## 12. Session catalog and search

Search is a projection over journals, not a second source of truth.

The global `Tackle.Session.Catalog` owns one in-memory ETS table of session entries (`Tackle.Session.Catalog.Entry`), rebuilt at every start (section 12.3). A journal owner records its session's entry when it opens an existing journal, when a sync makes new commits durable, when a turn starts or settles (whose commits are then appended but not yet synced), and when it stops; the store records forks, archive moves, and deletions. While the owner runs a turn the entry's status is `:active`; otherwise it is the status replay reports. Each entry carries `last_indexed_seq`, the commit it describes, which also keeps search text built for an older commit from being cached on a newer entry.

### 12.1 Searchable summary

A session result contains bounded metadata rather than its full transcript:

```text
session_id
title
cwd
created_at
updated_at
status              clean | interrupted | recovered | active
model
tags
message_count
preview
last_indexed_seq
parent_session_id
archived            the session lives under sessions/archive/
context_tokens      estimated model context (Projection.context_tokens/1), nil in old sidecars
stale               taken from a sidecar because replaying the changed journal timed out
```

List and search filters include:

```text
text
cwd
session_ids
status              an atom or its name ("active")
model
tags
archived            false by default, true for archived only, or :all
limit               50 by default
cursor
```

Created and updated range filters are planned, not implemented.

Lists are ordered newest first by `updated_at`, ties by `session_id`, which is stable. Pagination uses opaque cursors rather than mutable numeric offsets.

### 12.2 Indexed content

Default full-text search includes:

- explicit or derived title;
- user-message text;
- assistant-message text;
- cwd; and
- explicit tags.

It excludes by default:

- raw reasoning/thinking;
- provider continuation state;
- tool arguments;
- tool output; and
- arbitrary runtime context.

This reduces accidental secret exposure and index size. The durable journal can still retain conversation fields required for exact continuation.

Search text is built lazily, not per commit, because its cost grows with the
session. A live journal records summaries without it. A text search builds the
missing text for each candidate in the searching process, from the live
journal's projection or by replaying the session's file, and caches it on the
catalog entry until the session's next indexed commit. Startup indexing takes
it from summary sidecars (written once when a journal owner stops) or from the
replay it already performs.

### 12.3 Rebuild behavior

Derived catalog data uses atomically replaced ETF sidecars (`summary.etf`) to avoid replaying every complete journal during normal startup. Each sidecar includes its schema version, session ID, projected sequence, the size and modification time of the journal file it was built from, and the session's catalog entry with its search text (`Tackle.Session.Catalog.Entry.to_sidecar/1`; `from_sidecar/1` reads what any version wrote). A journal owner writes it when it stops, after closing its log; compression writes it from a full replay before it replaces the journal with its compressed copy.

On startup the catalog rebuilds its index in a task:

1. read every session's sidecar; one whose journal still has the recorded size and modification time, or whose journal is stored compressed (a compressed journal never changes), is used as it is;
2. replay every other journal, including those whose sidecar was written before sidecars recorded the file's size and modification time;
3. bound each step per session (two seconds by default); a replay that times out falls back to the session's sidecar, marked `stale`, and a session without one, or whose journal cannot be read, is skipped; the rebuild reports how many sessions it indexed, how many of them are stale, and how many it skipped; and
4. keep recording journal updates meanwhile, which win over what the rebuild read. Reads (`get`, `list`, `search`) wait until the rebuild has finished, so they never return a partial index.

A failed catalog update does not roll back an already durable session commit. The entry stays stale until the session's next indexed commit or the next rebuild.

The initial implementation should remain OTP-native and dependency-free. If measured scale later requires SQLite FTS5 or another specialized index, it can replace the derived search implementation without changing journals, session APIs, or durable semantics. A custom persistent full-text database is not part of the core design.

## 13. Checkpoints (planned)

Replay checkpoints are not implemented: nothing writes or reads `checkpoint.etf`, and every open replays the whole journal. This section is the plan. Checkpoints are optional and should not be introduced before measurements show a need.

A checkpoint may store a versioned plain projection in `checkpoint.etf` with:

- session ID;
- checkpoint schema version;
- last applied journal sequence;
- durable messages and metadata; and
- enough identity to reject a checkpoint belonging to another journal.

Checkpoint publication is:

```text
encode and validate
  → write temporary file in the same directory
  → sync temporary file
  → rename atomically
  → sync parent directory where supported
```

On any mismatch, decode error, unsupported version, or invalid projection, Tackle deletes or ignores the checkpoint and replays the journal. A checkpoint is never repaired as if it were history.

ETF is appropriate here because the checkpoint is local, derived, and disposable. The same plain-data restriction still applies.

## 14. Schema evolution and migration

Schema evolution occurs at three independent levels:

1. journal container/application `format_version` in the header;
2. commit-envelope `schema_version`; and
3. per-event `version`.

Readers use pure upcasters from old plain maps to the current in-memory schema. Every event is still at version 1, so no upcaster is registered yet; the mechanism is tested with a schema that has one. Reading an old journal does not rewrite it automatically. `Tackle.Session.Log` registers one upcaster per `{event_type, from_version}`, each producing the next version's event data; `Log.read_commit/4` applies them one version at a time before it validates the event, so the checks always describe the current version. A reader accepts every version from 1 up to the current one and rejects a newer version as unsupported. Bumping an event's version therefore requires an upcaster from every older version, which a test enforces.

An explicit migration (planned; no migration exists yet):

1. acquires exclusive session ownership;
2. replays and validates the source;
3. writes a complete new journal in a temporary session directory;
4. syncs and replays the new journal for validation;
5. atomically publishes the replacement where supported; and
6. retains the previous journal under `recovery/` until the migration is accepted.

In-place truncation, partial rewriting, and migration during ordinary load are prohibited.

Fixtures from every previously supported journal version remain in tests. `Tackle.Test.LegacyJournals` (`packages/tackle/test/support/legacy_journals.ex`) writes, with `:disk_log` as earlier versions did, a pre-tree linear journal, journals with a `session.closed`, a fork, the flat pre-project layout, an old summary sidecar, and a lock file without a process identity, and the tests read, resume, index, or reclaim each; the CLI has its own helper for resuming a closed legacy session. Tests also repair torn, corrupt, header-only, and compressed journals. OTP upgrades must verify that current `:disk_log` can replay and repair representative older files before release support is claimed.

## 15. Forking and lineage

A fork creates a new independent session at a validated commit sequence:

1. flush a live parent, then replay it (the requested sequence must be one of its commits);
2. create a new session ID and journal in a temporary directory;
3. write a header with parent session ID and sequence, and a `session.forked` commit;
4. copy the parent's validated commits up to that sequence, renumbered from 2 and without the parent's `session.recovered` and legacy `session.closed` events (`Tackle.Session.Reader.write_journal/2`);
5. sync, close, and replay the new journal;
6. atomically publish the new session directory; and
7. update the catalog.

The child can be loaded after the parent is deleted. Parent metadata exists for lineage and navigation, not for replay dependency.

Branching several histories inside one file is implemented as a conversation
tree. A session's projection and runtime state always fold a `Tackle.Lib.Tree`;
the `session.created` event records whether the session may branch, which the
session enforces by rejecting navigation with `:tree_disabled` otherwise. In a
branching session `message.appended` carries the entry parent link,
`context.compacted` attaches to the active branch, and `tree.navigated` records
a committed position change; a session without branching writes neither parent
link (each entry attaches to the one before it), so its journal keeps the
format it always had. The canonical archive (`Projection.messages`) covers
every branch once, while the active transcript and model context follow the
selected ancestry. A journal without branching loads as a single-branch tree
and records an explicit `tree.enabled` transition before its first branching
write. Independent forks remain one file per session and copy the
tree and active position; see
[the conversation tree plan](SESSION_TREE_PLAN.md), which retains the existing
journal durability contract.

## 16. Deletion and retention

Deleting an inactive session initially renames its complete directory into `sessions/trash/` and removes it from the catalog. Renaming first prevents a partial multi-file deletion from leaving a session that appears live.

Active sessions cannot be deleted: a session live in this node is refused with `:session_active`, and one whose writer lock another process holds with `{:session_in_use, owner}`. Nothing purges the trash yet; a permanent purge would be a separate explicit operation. The canonical default retention policy is indefinite until a user or embedding host configures otherwise.

No retention policy may silently convert a complete journal into a wrap log. If long histories need compaction, the system must preserve an explicit archive or write a new independently valid compacted session with documented semantic loss.

## 17. Import, export, and protocol integration

Internal `.dlog` files are not portable imports. Tackle must reject attempts to import an arbitrary internal log directly.

Portable export operates on the validated durable projection and may later provide formats required by actual consumers, such as:

- a stable Tackle JSON archive;
- JSONL for common command-line tooling;
- ACP session history;
- AG-UI events; or
- RFC 7464 if a concrete consumer requires it.

Export is not allowed to expose credentials or unrestricted runtime context. Imports decode a portable data format, validate every field and size, and create a fresh local `:disk_log` journal through the normal writer.

CloudEvents, AG-UI, ACP, and OpenTelemetry solve event interchange, client protocol, or observability concerns; none is adopted as the canonical on-disk schema.

## 18. Ephemeral agents, scripted workflows, and fleets

The runtime architecture's initial delegated agents remain ephemeral:

```text
parent durable root session
  → starts ephemeral child
  → child result becomes a durable parent tool result
  → child process and in-memory conversation terminate
```

That preserves the complete durable root conversation without creating one session directory for every small delegated request.

A future explicit retained-child policy may give a subagent its own journal and record links between parent session, parent turn, child session, and child run. It must use the same session-journal contract rather than writing child state into a special fleet log.

Runtime scope membership, live fleet accounting, script process state, pending requests, and cancellation trees are not reconstructed by loading a session. Durable scripted workflows require a separate compatibility-sensitive architecture because replaying a conversation is not equivalent to safely replaying external workflow effects.

## 19. Security and privacy

Session journals can contain source code, prompts, reasoning, tool output, cwd values, provider continuation state, and other sensitive developer data.

Required protections include:

- private storage-root and session-directory permissions;
- restrictive journal and projection file permissions;
- no credentials, credential handles, or credential-shaped adapter options;
- bounded file, item, collection, nesting, and binary sizes;
- `bchunk` plus `binary_to_term(..., [:safe])` for ordinary replay;
- full durable-schema validation after decoding;
- no execution or module dispatch derived from persisted terms;
- no direct import of internal logs;
- no reasoning, tool output, or provider state in search by default; and
- explicit reporting of repair, corruption, and unsupported schemas.

The `:safe` ETF option is necessary but insufficient. It prevents specific VM resource attacks; it does not establish that decoded data is valid or appropriate for Tackle.

Encryption at rest, cryptographic tamper evidence, and cross-machine trust are deferred. Filesystem permissions are the initial local threat boundary.

## 20. Implementation plan

Status: tasks 1 to 6 are implemented, as are forks and deletion from task 7
and task 8 apart from the ACP mapping. Checkpoints are not (section 13), and
no import exists, so none can accept an internal log.

### Task 1: durable contracts and codecs

Define plain-data structures and codecs for:

- session headers;
- commit envelopes;
- event versions;
- messages and usage;
- metadata and lineage; and
- replay projections and recovery status.

Acceptance criteria:

- durable conversion never serializes `%Tackle.Lib.State{}` directly;
- forbidden runtime terms are rejected;
- decode and encode limits are enforced;
- public durable contracts have documentation and specs; and
- round-trip tests cover every initial event type.

### Task 2: journal owner (`Tackle.Session.Journal`)

Implement the supervised owner around one internal halt `:disk_log`.

Acceptance criteria:

- one process owns sequence assignment and the log lifecycle;
- one commit is one logged term;
- append errors and sync errors propagate;
- notifications change journal health visibly;
- journal-owner failure terminates its durable scope; and
- clean close syncs before releasing ownership.

### Task 3: replay and repair

Implement bounded chunk replay, safe explicit decoding, validation, and controlled repair.

Acceptance criteria:

- replay reconstructs the same durable projection after clean close;
- an unclean close is repaired and reported;
- bad-byte repair is visible;
- sequence gaps, duplicates, invalid commits, and unknown required versions prevent writable resume;
- the original unclean file is retained before destructive repair; and
- untrusted `.dlog` import is rejected.

### Task 4: root-scope integration

Add the journal as a critical child for durable root scopes and attach the internal persistence hook.

Acceptance criteria:

- turn start is durable before its Task begins (since relaxed: appended
  write-behind; see section 9);
- each settled message is durable before the next provider or tool effect
  (since relaxed: messages are durable at the next sync point; see section 9);
- tool intent is durable before tool execution (external tools; read-only tools
  skip the sync);
- terminal settlement is durable before terminal delivery (since relaxed:
  appended write-behind before delivery; see section 9);
- persistence failure aborts rather than degrading to memory-only execution; and
- scopes without a session spec continue to work without a journal.

### Task 5: loading and resume

Rebuild a fresh runtime from a durable projection and current trusted configuration.

Acceptance criteria:

- session ID and message IDs remain stable;
- runtime and credential values are always fresh;
- unavailable recorded configuration returns a typed error;
- clean sessions resume normally;
- interrupted tool effects require explicit recovery; and
- loading does not reconstruct old scopes, descendants, Tasks, or script runs.

### Task 6: catalog, listing, and search

Add a global derived catalog with initial ETS-backed discovery and search.

Acceptance criteria:

- list and search do not mutate journals;
- results have stable cursor pagination;
- stale projections catch up (journal updates replace entries; startup trusts a
  sidecar only while its journal keeps the recorded size and modification time);
- corrupt or incompatible summaries rebuild from journals;
- search-index failure does not lose history; and
- sensitive fields are excluded from default indexing.

### Task 7: forks, deletion, and checkpoints

Implement self-contained forks, trash-first deletion, and checkpoints only if replay measurements justify them.

Acceptance criteria:

- a fork survives deletion of its parent;
- fork publication is atomic from the catalog's perspective;
- active sessions cannot be deleted;
- checkpoints can always be removed and rebuilt; and
- no operation rewrites the source journal in place.

### Task 8: frontend and protocol integration

Expose session creation, discovery, resume, recovery prompts, and deletion through the root facade and CLI. Map ACP operations when ACP integration is added.

Acceptance criteria:

- the CLI defaults root conversations to durable sessions;
- interrupted and repaired states are visible;
- live runtime references remain PID-free;
- exact commands and public behavior are documented; and
- no provider-specific persistence path is introduced.

## 21. Validation priorities

The persistence implementation requires deterministic tests and fault injection rather than only successful round trips.

Highest-priority cases are:

1. kill the journal owner without closing, then repair and replay;
2. kill the complete BEAM immediately before and after each `sync/1` boundary;
3. truncate or damage the final logged item;
4. damage bytes in the middle and verify sequence/corruption handling;
5. inject write, full-disk, permission, and sync errors;
6. crash a turn after `tool.execution_started` but before its result;
7. crash after a tool result but before terminal settlement;
8. attempt two writable owners for one file;
9. replay unknown optional and required event versions;
10. reject PIDs, functions, refs, oversized terms, and unsafe imported data;
11. compare journal replay with the settled in-memory message projection;
12. rebuild every catalog and checkpoint file from journals; and
13. replay fixture logs across every supported OTP upgrade.

Benchmarks should measure rather than assume:

- append plus sync latency;
- replay time for long sessions;
- disk usage for realistic prompts and tool results;
- cold and warm catalog startup;
- search performance across thousands of sessions; and
- whether checkpoints or compression provide meaningful benefit.

`:disk_log.log/2` does not compress terms by default. Manual pre-encoding with compressed ETF is deferred until benchmarks justify the extra codec and decompression risk.

Tests use fake adapters and tools and require no provider credentials. Filesystem crash tests should use temporary directories and preserve failure artifacts when diagnosis is useful.

## 22. Standards and reference systems

The design was informed by:

- OTP `:disk_log` internal framing, repair, ownership, chunk, and sync semantics;
- OTP External Term Format and secure-decoding guidance;
- Pi's monotonic sequence-numbered commits, transaction records, tail repair, atomic forks, and rebuildable indexes;
- grok-build's serialized persistence actor, explicit durability barriers, atomic snapshots, and rebuildable SQLite FTS catalog;
- RFC 7464 JSON Text Sequences;
- RFC 8742 CBOR Sequences;
- RFC 9562 UUIDs;
- ACP session load, resume, and proposed list semantics;
- AG-UI event serialization and lineage; and
- SQLite WAL behavior for a possible future derived search index.

There is no identified universal agent-session file standard. Tackle therefore uses OTP-native local storage while keeping its application schema explicit and its protocol/export boundaries independent.

## 23. Architectural invariants

The session architecture is correctly shaped when all of the following remain true:

- Each durable session has one canonical append-only journal.
- The canonical journal is an internal, halt-mode `:disk_log`.
- Exactly one supervised owner assigns sequences and writes one session journal.
- One logical commit is one versioned logged term.
- A successful append is not reported durable until `:disk_log.sync/1` succeeds.
- The runtime does not continue a durable session after journal failure.
- `%Tackle.Lib.State{}` and runtime structs are never serialized wholesale.
- Durable records contain constrained plain data and stable IDs.
- Session identity remains stable while runtime scope and agent references change on resume.
- Loading combines durable conversation data with fresh trusted executable configuration.
- Streaming deltas remain observational; settled messages and semantic boundaries are durable.
- A tool start without a durable result is treated as an uncertain external effect.
- Repair is visible, validated, and limited to trusted local journals.
- Complete invalid commits are not silently skipped.
- Wrap and rotate logs are not used for canonical history.
- Search, summaries, and checkpoints are disposable projections.
- An ephemeral subagent result is persisted in its durable parent's transcript, not automatically as another independent session.
- Forks are self-contained and atomically published.
- Internal `.dlog` files are never accepted as untrusted portable imports.
- `Tackle.Lib` remains independent of storage, search, frontends, and runtime orchestration.

## 24. Deferred decisions

The following remain deferred until implementation evidence or a real consumer requires them:

- cross-host writer fencing and distributed leases (one host's BEAMs are fenced by `flock`);
- distributed or replicated session storage;
- durable scripted-workflow and fleet reconstruction;
- retained long-lived subagent sessions;
- checkpoint thresholds;
- compressed ETF commit encoding;
- large content-addressed blob storage for oversized tool results or attachments;
- SQLite FTS5 or another specialized derived search backend;
- encryption at rest and cryptographic tamper evidence;
- a portable archive format beyond protocol-specific export needs;
- automatic retention and semantic compaction policy; and
- live attachment with replay during an already active turn.

These deferrals must not weaken the accepted core: one OTP-native durable journal per session, one writer, explicit sync barriers, validated replay into fresh runtime state, and rebuildable discovery/search projections.

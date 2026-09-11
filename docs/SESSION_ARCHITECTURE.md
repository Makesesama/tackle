# Tackle session persistence, recovery, and search architecture

Status: accepted architecture; core implemented. The root harness now stores one
append-only internal `:disk_log` journal per session with a single supervised
writer, explicit `sync/1` barriers, validated replay with visible repair, fresh
runtime reconstruction on resume with an explicit interruption-recovery gate, a
rebuildable ETS/search catalog, self-contained forks, and trash-first deletion.
Replay checkpoints, in-place schema migration, cross-BEAM writer fencing,
durable workflows, encryption, compressed commits, retention policy, and
protocol export/import remain unimplemented; this document is the accepted
target for them. The `Tackle.*` operations listed in section 11 are the
implemented subset unless a passage explicitly labels them as deferred.

Scope: saving and loading agent conversations, crash recovery after process or BEAM shutdown, local session discovery and search, schema evolution, and session forks. Durable workflows, distributed storage, and transparent reconstruction of the in-memory runtime process tree remain out of scope.

This document resolves the session-persistence decisions deferred by [`RUNTIME_ARCHITECTURE.md`](RUNTIME_ARCHITECTURE.md). It preserves that document's runtime boundaries: `Tackle.Lib` remains the provider-neutral loop, the root Tackle harness owns persistence and orchestration, and runtime references remain distinct from durable conversation identity.

## 1. Agreed direction

1. Tackle uses one append-only journal as the canonical durable source of truth for each persisted agent session.
2. The journal uses Erlang/OTP's `:disk_log` in `:internal`, `:halt` mode. Tackle does not define a second framing layer or add a persistence dependency for the initial implementation.
3. The internal `:disk_log` file is trusted, Tackle-owned local state. It is not an interchange format and is never opened directly from an untrusted import.
4. Each logged item is one self-contained, versioned Tackle commit. A commit contains one or more related domain events and one monotonic session sequence number.
5. `%Tackle.Lib.State{}` is not serialized. The durable schema contains only deliberate conversation data and audit metadata represented as plain values.
6. Saving is continuous. There is no ordinary user-visible “save the current struct” operation. Explicit flushing exists only as a durability barrier.
7. Tackle calls `:disk_log.sync/1` at semantic commit boundaries before allowing later external effects or announcing terminal completion.
8. One supervised journal owner serializes every write to one session. A session journal has at most one writable owner.
9. A journal failure is fatal to further durable execution of that session. Tackle fails closed rather than continuing with memory-only state after persistence has failed.
10. Loading replays durable conversation data into a fresh, trusted runtime configuration. It never restores PIDs, Tasks, runtime references, credential handles, executable modules, or stale process state.
11. Search, summaries, checkpoints, and indexes are derived projections. They may lag, be deleted, or be rebuilt without changing the durable session.
12. Streaming token deltas and frontend-only events are not canonical history. Tackle persists settled messages, turn boundaries, tool-execution boundaries, configuration changes, and terminal outcomes.
13. The CLI's root conversations are durable by default. Ephemeral delegated agents remain ephemeral unless a later explicit retention policy gives them independent durable sessions.
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

A runtime scope is the in-memory supervision and cancellation boundary defined by [`RUNTIME_ARCHITECTURE.md`](RUNTIME_ARCHITECTURE.md). Values such as `ScopeRef`, `AgentRef`, workflow IDs, PIDs, monitors, Tasks, cancellation signals, and request helpers are ephemeral.

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
- **Checkpoint:** a disposable projection snapshot used to accelerate replay.
- **Catalog:** a rebuildable index used to list and search sessions.

The word “WAL” can describe the write-before-effect discipline, but “session journal” is more precise. The journal is itself the durable history; there is no second durable conversation file updated in place.

## 4. Relationship to the current runtime

The current runtime keeps one settled `%Tackle.Lib.State{}` in each `Tackle.Session` and runs one active turn in a supervised Task. That remains the in-memory ownership model.

A durable root scope adds one critical journal owner:

```text
Tackle.Supervisor
├── Tackle.Auth.Store
├── Tackle.Runtime.Registry
├── SessionCatalog                         derived search/list projection
└── Tackle.AgentSupervisor
    └── AgentScope
        ├── ScopeCoordinator
        ├── Root SessionJournal            one writable owner
        ├── Root Tackle.Session
        └── WorkSupervisor
            ├── root turn Task
            ├── ephemeral subagent sessions
            ├── workflows
            └── descendant turn Tasks
```

The exact child ordering and module names may change, but these behaviors are required:

- the journal owner is available before the root session accepts work, and a new session is materialized before its first turn Task starts;
- the root session and its internal persistence hook can make synchronous journal calls;
- a journal-owner failure prevents further execution and terminates the durable scope;
- orderly scope shutdown syncs and closes the journal;
- an ephemeral scope may omit the journal entirely; and
- one journal process never becomes a global bottleneck across unrelated sessions.

A dedicated journal owner is justified even though `:disk_log` has its own process. The Tackle owner holds the application sequence, validates commits, applies durability policy, owns the `:disk_log` lifecycle, and provides one narrow API to the session and loop hook. Callers do not open or write the file directly.

## 5. Storage layout

The initial local layout is rooted under `TACKLE_HOME`:

```text
$TACKLE_HOME/
└── sessions/
    ├── catalog/                           derived global data
    ├── trash/                             recoverable deletions
    └── <session-id>/
        ├── session.dlog                   canonical journal
        ├── summary.etf                    optional derived summary
        ├── checkpoint.etf                 optional derived replay checkpoint
        └── recovery/                      pre-repair or migration artifacts
```

Session IDs are used as opaque path components after validation. If directory fan-out becomes a measured problem, the implementation may add deterministic sharding without changing session identity or the journal schema.

The journal is the only required durable file. `summary.etf`, `checkpoint.etf`, and catalog data can always be removed and recreated.

Session directories should be private to the current user, and journal files should be created with restrictive permissions. Filesystem permissions are part of the security boundary because internal repair and ordinary `:disk_log.chunk/2` can decode ETF terms.

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

Only the journal-owner process calls `open/1`, `log/2`, `sync/1`, or `close/1`. Other runtime processes use the owner's API. Notifications including `error_status`, `full`, `truncated`, and unexpected wrap events are handled explicitly.

### 6.1 One-writer invariant

OTP serializes callers using the same open log on one node, but it does not prevent the same file from being opened under another name, in another BEAM, or on another node. OTP documents that concurrent writable opens can corrupt the file.

The initial storage contract is therefore:

```text
one TACKLE_HOME
  → one writable Tackle application at a time per session
  → one journal owner
  → one :disk_log process
```

A deterministic log name protects against duplicate opens within one connected node. A storage ownership guard must reject concurrently active writers when detectable. Cross-BEAM failover and distributed leases are not promised. If ownership is uncertain, Tackle fails with `:session_in_use` or a recovery-required error rather than opening with automatic repair.

A later advisory-lock or fencing implementation may strengthen cross-process ownership without changing journal records.

### 6.2 Deferred materialization of new sessions

The journal owner process starts with its durable scope, so scope supervision and fail-closed behavior are unchanged. A *new* session is not materialized until its first prompt, however. Until then the owner holds the validated session id, storage options, and creation metadata in memory and writes nothing:

- no session directory, ownership lock, `session.dlog`, or `session.created` commit exists;
- the catalog has no entry, so opening and quitting the CLI creates no visible session;
- an idle reconfiguration or metadata change only updates the metadata that the eventual `session.created` commit will record;
- `Tackle.Session.Journal.projection/1` reports a provisional, empty projection so the frontend can resolve configuration exactly as it would for a materialized session; and
- closing or flushing an unmaterialized journal is a no-op.

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

The header can be supplied through the internal log's `head` option or written as the first validated item. Replay treats it as sequence zero either way. It is immutable after creation; changes such as title, tags, or current working directory are later events.

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
- `commit_id` is unique;
- `events` is a non-empty list;
- each event has an independently versioned schema;
- every value passes the durable-data validator; and
- one commit remains below an application-defined maximum item size substantially lower than `:disk_log`'s 4 GB term limit.

Unknown required events stop replay with an unsupported-schema error. Unknown optional extension events can be retained while the core projection ignores them.

### 7.4 Event types

The initial durable event algebra includes:

```text
session.created
session.metadata_changed
session.configuration_changed
session.recovered
session.closed
turn.started
message.appended
context.compacted
tool.execution_started
turn.completed
turn.errored
turn.cancelled
turn.crashed
turn.abandoned
session.forked
```

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

Tool definitions, prompt renderers, adapters, and hook modules are not stored as executable terms. Audit events may store model references, tool names, and prompt/tool version hashes.

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

1. `Tackle.Session` asks the journal to append and sync `turn.started`, including the raw submitted input for audit and recovery diagnostics. For a new session this first commit also materializes the journal: the owner acquires ownership, opens the log, and writes the header and `session.created` first.
2. Only after that succeeds does the session start the supervised turn Task.
3. `Tackle.Lib.Loop` constructs and settles the user message.
4. The internal `after_message` hook appends and syncs `message.appended` before the loop performs the first provider request.
5. If persistence fails, the hook aborts the turn and the session does not continue in memory-only mode.

The settled user message, rather than the raw input in `turn.started`, is the conversation projection. A crash before that message commits leaves an interrupted attempt but does not fabricate a message during replay.

### 8.2 Continuing without a new message

For `continue`:

1. the session appends and syncs `turn.started` with operation `continue`;
2. the Task starts only after the commit succeeds; and
3. the loop proceeds using the existing durable conversation.

### 8.3 Assistant messages and tools

The existing hook lifecycle provides the required boundaries:

- `after_message` persists a settled assistant or tool message;
- `before_tool_call` persists and syncs `tool.execution_started` before invoking the tool; and
- a settled tool-result message is persisted and synced before the next provider request.

This creates an honest recovery distinction:

```text
tool.execution_started with a later tool message
  → tool result is known and replayable

tool.execution_started without a later tool message
  → tool may have produced an external effect; outcome is uncertain
```

Tackle must never automatically repeat an uncertain tool execution merely because its result is absent.

Library streaming events can reach a live subscriber before the persistence hook completes. They remain observational. The durability guarantee is that a settled message is committed before the loop performs the next provider or tool effect, and that terminal completion is not announced before the terminal journal commit is synced.

### 8.4 Terminal settlement

After the turn Task settles or crashes, `Tackle.Session` appends the corresponding terminal event and syncs it before:

- replacing the session's settled in-memory state;
- broadcasting `:tackle_turn_finished` or `:tackle_turn_failed`;
- delivering an ephemeral correlated outcome; or
- accepting another turn.

Expected outcomes remain distinct:

```text
turn.completed
turn.errored
turn.cancelled
turn.crashed
```

A Task crash is never rewritten as a normal library error.

### 8.5 Reconfiguration

An idle model or thinking-level change is persisted before it becomes the accepted session configuration. The event stores only durable selections and audit hashes, not executable adapter modules or credentials.

If the journal commit fails, `Tackle.Session.reconfigure/2` returns an error and retains the previous configuration.

### 8.6 Closing

Orderly close performs:

1. cancellation and settlement of an active turn according to current runtime rules;
2. a `session.closed` commit when appropriate;
3. `:disk_log.sync/1`;
4. `:disk_log.close/1`; and
5. release of journal ownership.

A process or BEAM crash can skip these steps. Recovery must therefore rely on journal repair and replay, not on the presence of `session.closed`.

## 9. Durability contract

`:disk_log.log/2` is synchronous with the log process but does not guarantee stable storage. OTP internally buffers writes and the operating system may buffer them again. The initial implementation therefore has one simple durability policy:

```text
semantic commit
  → :disk_log.log/2
  → :disk_log.sync/1
  → acknowledge success
```

There is no initial user-configurable buffered durability mode. Agent provider and tool operations are normally much slower than a local sync, and a single safety-first contract is simpler to explain and test.

`sync/1` is the strongest durability operation provided by OTP, not a promise that every filesystem, device controller, or virtualized disk honors physical persistence perfectly. Tackle reports its guarantee as successful completion of the OTP/file sync boundary.

The implementation must propagate full-disk, permission, device, sync, and log-process failures. It must never suppress them to preserve apparent agent progress.

### 9.1 Compaction durability barrier

Checkpoint compaction is the one session operation that changes the
provider-visible projection rather than appending to it. It preserves the same
fail-closed contract:

1. `Tackle.Lib.Compaction` selects and snapshots a balanced plan without mutation;
2. it generates and strictly validates the summary (non-empty, complete, no tool
   calls, strictly smaller than the shadowed region);
3. it commits one `context.compacted` event through `Tackle.Session.Compaction`,
   which resolves the live journal by session id and syncs the commit;
4. only after a successful commit does it install the replacement in
   `State.model_messages`.

A summarizer, validation, or commit failure leaves the model context unchanged. A
commit failure is returned as `{:error, {:durable_commit_failed, reason}}` so the
loop fails the turn instead of continuing with an unpersisted checkpoint. The
canonical transcript is never compacted, so history remains append-only,
inspectable, searchable, and forkable.

## 10. Loading, replay, and runtime reconstruction

### 10.1 Replay

A reader folds records in sequence order:

1. validate the header and supported physical format;
2. read internal items in bounded chunks;
3. decode and validate one durable commit at a time;
4. require contiguous sequence numbers and unique commit IDs;
5. upcast known older event versions in memory;
6. apply events to a plain durable projection; and
7. classify the final session as clean, closed, interrupted, recovered, corrupt, or unsupported.

Normal replay should prefer `:disk_log.bchunk/2,3`, which returns encoded item binaries, followed by controlled decoding with:

```elixir
:erlang.binary_to_term(binary, [:safe])
```

This prevents creation of new atoms and new external function references during ordinary replay. Durable validation is still required after decoding; `:safe` protects the VM from specific ETF hazards, not the application from malicious or nonsensical values.

### 10.2 Repair

Internal `:disk_log` can repair an uncleanly closed log, but repair is not treated as silent success.

The recovery path is:

1. establish exclusive application ownership;
2. first open or inspect without destructive repair when practical;
3. preserve the original unclean file under `recovery/` before repair;
4. invoke internal repair;
5. record the returned recovered-item and bad-byte counts;
6. replay every recovered commit through normal schema and sequence validation; and
7. append and sync `session.recovered` only after validation succeeds.

If repair reports bad bytes, the session is visibly marked as recovered. If replay finds a gap, duplicate, invalid envelope, unsupported required event, or inconsistent terminal state, the session is quarantined from writable resume. Tackle does not silently skip a complete invalid commit.

`:disk_log` internal repair uses ETF decoding internally. Therefore repair is allowed only for the private trusted storage root. Imported or attacker-controlled files must never enter this path.

### 10.3 Incomplete turns

A `turn.started` event without a matching terminal event makes the session interrupted. Replay also identifies tool starts without durable results.

The durable projection reports at least:

```elixir
%{
  status: :interrupted,
  turn_id: turn_id,
  last_seq: seq,
  uncertain_tools: [...]
}
```

Opening the session read-only always remains possible when replay validates. Writable resume appends a recovery decision such as `turn.abandoned` before accepting new work.

If unresolved tools may have produced side effects, automatic continuation is prohibited. The frontend must let the user inspect the uncertainty and explicitly abandon, repair, or otherwise resolve it.

### 10.4 Reconstructing `Tackle.Lib.State`

Replay does not deserialize a state struct. It produces a durable projection containing messages, metadata, selections, lineage, and recovery status.

Runtime reconstruction then:

1. loads current trusted `Tackle.Config` and credentials;
2. resolves the recorded model/profile or an explicit user override;
3. creates a fresh `%Tackle.Lib.State{}`;
4. replaces its generated session ID with the durable session ID;
5. installs validated durable messages in order (both the complete transcript in
   `State.messages` and the replayed provider projection in
   `State.model_messages`);
6. resets runtime status, error, pending assistant state, snapshot, hooks, tools, registries, and context appropriately;
7. attaches fresh runtime handles and cancellation state; and
8. records a durable configuration change if the user selected a different model or profile.

If the recorded configuration cannot be resolved, loading returns a typed configuration-required result. It does not silently switch providers or models.

## 11. Load, resume, and inspect semantics

Internally, one replay operation supplies several public use cases:

- **inspect:** read and project a session without creating an agent scope;
- **load:** create a runtime and replay history to an attaching frontend;
- **resume:** create a runtime from the same durable projection without requiring the frontend to receive historical events again; and
- **fork:** materialize a new durable session from a selected validated sequence.

This distinction aligns with the Agent Client Protocol's session concepts: ACP `session/load` replays history to the client, whereas `session/resume` restores the agent-side session without replaying that history. ACP does not define Tackle's local storage format.

The exact public API is deferred, but the conceptual operations are:

```elixir
Tackle.create_session(scope_spec, opts)
Tackle.inspect_session(session_id, opts)
Tackle.load_session(session_id, scope_spec, opts)
Tackle.resume_session(session_id, scope_spec, opts)
Tackle.list_sessions(filters)
Tackle.search_sessions(query, filters)
Tackle.fork_session(session_id, opts)
Tackle.delete_session(session_id, opts)
Tackle.flush_session(session_id)
```

These operations return stable session metadata and PID-free runtime references. They never expose the journal process or `:disk_log` name.

## 12. Session catalog and search

Search is a projection over journals, not a second source of truth.

A global `SessionCatalog` may own ETS tables containing session summaries and searchable terms. It receives updates only after journal commits have succeeded. Each indexed record carries `last_indexed_seq` so startup and repair can detect stale projections.

### 12.1 Searchable summary

A session result contains bounded metadata rather than its full transcript:

```text
session_id
title
cwd
created_at
updated_at
status
model
tags
message_count
preview
last_indexed_seq
parent_session_id
```

List and search filters initially include:

```text
text
cwd
status
model
tags
created range
updated range
limit
cursor
```

List ordering is stable by `(updated_at, session_id)`. Pagination uses opaque cursors rather than mutable numeric offsets.

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

### 12.3 Rebuild behavior

Derived catalog data may use atomically replaced ETF sidecars to avoid replaying every complete journal during normal startup. Each sidecar includes its schema version, session ID, and projected sequence.

On startup:

1. load valid summaries into ETS;
2. compare their projected sequence with journal state;
3. replay missing tails;
4. rebuild missing or incompatible summaries; and
5. make partial indexing status visible rather than pretending results are complete.

A failed catalog update does not roll back an already durable session commit. It marks the projection stale and schedules repair.

The initial implementation should remain OTP-native and dependency-free. If measured scale later requires SQLite FTS5 or another specialized index, it can replace the derived search implementation without changing journals, session APIs, or durable semantics. A custom persistent full-text database is not part of the core design.

## 13. Checkpoints

Replay checkpoints are optional and should not be introduced before measurements show a need.

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

Readers use pure upcasters from old plain maps to the current in-memory schema. Reading an old journal does not rewrite it automatically.

An explicit migration:

1. acquires exclusive session ownership;
2. replays and validates the source;
3. writes a complete new journal in a temporary session directory;
4. syncs and replays the new journal for validation;
5. atomically publishes the replacement where supported; and
6. retains the previous journal under `recovery/` until the migration is accepted.

In-place truncation, partial rewriting, and migration during ordinary load are prohibited.

Fixtures from every previously supported journal version should remain in tests. OTP upgrades must verify that current `:disk_log` can replay and repair representative older files before release support is claimed.

## 15. Forking and lineage

A fork creates a new independent session at a validated commit sequence:

1. replay the parent through the requested sequence;
2. create a new session ID and journal in a temporary directory;
3. write a header with parent session ID and sequence;
4. write a self-contained imported-history commit or equivalent versioned commits;
5. sync, close, and replay the new journal;
6. atomically publish the new session directory; and
7. update the catalog.

The child can be loaded after the parent is deleted. Parent metadata exists for lineage and navigation, not for replay dependency.

Branching several histories inside one file is now implemented as an optional
conversation tree. A session's projection always folds a `Tackle.Lib.Tree`; the
`session.created` event records tree enablement, `message.appended` carries the
entry parent link, `context.compacted` attaches to the active branch, and
`tree.navigated` records a committed position change. The canonical archive
(`Projection.messages`) covers every branch once, while the active transcript
and model context follow the selected ancestry. A legacy linear journal loads
unchanged and records an explicit `tree.enabled` transition before its first
branching write. Independent forks remain one file per session and copy the
tree and active position; see
[the conversation tree plan](SESSION_TREE_PLAN.md), which retains the existing
journal durability contract.

## 16. Deletion and retention

Deleting an inactive session initially renames its complete directory into `sessions/trash/` and removes it from the catalog. Renaming first prevents a partial multi-file deletion from leaving a session that appears live.

Permanent purge is a separate explicit operation. Active sessions cannot be deleted. The canonical default retention policy is indefinite until a user or embedding host configures otherwise.

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

## 18. Ephemeral agents, workflows, and fleets

The runtime architecture's initial delegated agents remain ephemeral:

```text
parent durable root session
  → starts ephemeral child
  → child result becomes a durable parent tool result
  → child process and in-memory conversation terminate
```

That preserves the complete durable root conversation without creating one session directory for every small delegated request.

A future explicit retained-child policy may give a subagent its own journal and record links between parent session, parent turn, child session, and child run. It must use the same session-journal contract rather than writing child state into a special fleet log.

Runtime scope membership, live fleet accounting, workflow process state, pending requests, and cancellation trees are not reconstructed by loading a session. Durable workflows require a separate compatibility-sensitive architecture because replaying a conversation is not equivalent to safely replaying external workflow effects.

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

### Task 2: `SessionJournal` owner

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

- turn start is durable before its Task begins;
- each settled message is durable before the next provider or tool effect;
- tool intent is durable before tool execution;
- terminal settlement is durable before terminal delivery;
- persistence failure aborts rather than degrading to memory-only execution; and
- ephemeral scopes continue to work without a journal.

### Task 5: loading and resume

Rebuild a fresh runtime from a durable projection and current trusted configuration.

Acceptance criteria:

- session ID and message IDs remain stable;
- runtime and credential values are always fresh;
- unavailable recorded configuration returns a typed error;
- clean sessions resume normally;
- interrupted tool effects require explicit recovery; and
- loading does not reconstruct old scopes, descendants, Tasks, or workflows.

### Task 6: catalog, listing, and search

Add a global derived catalog with initial ETS-backed discovery and search.

Acceptance criteria:

- list and search do not mutate journals;
- results have stable cursor pagination;
- stale projections catch up by sequence;
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

- the exact public module and function names;
- cross-BEAM advisory locking and distributed writer fencing;
- distributed or replicated session storage;
- durable workflow and fleet reconstruction;
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

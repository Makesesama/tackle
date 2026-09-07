defmodule Tackle.Phoenix.Store do
  @moduledoc """
  Host seam for everything `Tackle.Phoenix.Runner` must *not* own: persistence,
  state enrichment, quota, and billing.

  The Runner owns the generic turn lifecycle (task supervision, cancellation
  signal, PubSub fan-out, settlement, TTL) and calls out to a host `Store` at a
  handful of well-defined hooks. Keeping these host-side is deliberate: in a
  multi-tenant product, org scoping, credit spend, and quota enforcement must
  live with the host and survive untrusted input — this library never ships a
  free-path default that bypasses billing.

  All callbacks receive and return an opaque host `state` term (the Runner
  threads it through unchanged), plus the `Tackle.Lib.State` where relevant. The
  Runner treats `Tackle.Lib.State.context` as opaque; only the host's `enrich_state`
  populates persistence/org context into it.

  ## Hook ordering within a turn

    1. `before_turn/2` — quota/permission gate. Returning `{:error, reason}`
       aborts the turn before any work; the Runner replies with that reason.
    2. `enrich_state/3` — inject host persistence/org context into
       `Tackle.Lib.State.context` (session id, user id, org id, persisted ids).
    3. `persist_user_message/3` — persist the user's input message (run turns).
    4. `persist_pending_message/3` — persist an in-flight assistant message on
       `:message_start` (best-effort), with the active turn correlation options.
    5. `settle_turn/4` — on task result: update DB session, persist final
       messages, and charge billing. Returns the host state to keep.
    6. `after_turn/3` — fire-and-forget host follow-ups (e.g. title generation).
  """

  alias Tackle.Lib.State
  alias Tackle.Lib.Usage

  @typedoc "Opaque host-managed state threaded through the Runner."
  @type host_state :: term()

  @typedoc """
  Per-turn options passed from the caller (user_id, session_id,
  organization_id, ...). Run turns also include the effective
  `:user_message_id`, normalized `:turn_metadata`, and
  `:pre_persisted_message?` flag.
  """
  @type turn_opts :: keyword()

  @typedoc "Settled turn result as produced by the agent loop."
  @type turn_result ::
          {:ok, State.t()} | {:error, State.t()} | {:cancelled, State.t()} | term()

  @typedoc """
  Optional host-mailbox action. The Runner remains unaware of the message's
  transport or meaning; it only knows how to start an ordinary correlated turn.
  """
  @type host_message_result ::
          :unhandled
          | {:noreply, host_state()}
          | {:run_turn, host_state(), binary(), turn_opts()}

  @doc """
  Initializes process-local host concerns after the Runner starts.

  A host may use this optional callback to subscribe the Runner process to a
  private transport topic. It must return the updated opaque host state.
  """
  @callback init_host(host_state()) :: host_state()

  @doc """
  Handles a mailbox message not owned by the generic Runner.

  Returning `{:run_turn, state, input, opts}` asks the Runner to execute the
  input through its normal gate, correlation, persistence, settlement,
  cancellation, and billing lifecycle. Unknown messages should return
  `:unhandled`.
  """
  @callback handle_host_message(host_state(), term()) :: host_message_result()

  @doc """
  Gate a turn before any work happens (quota/permission). `{:error, reason}`
  aborts; `:ok` proceeds.
  """
  @callback before_turn(host_state(), turn_opts()) :: :ok | {:error, term()}

  @doc """
  Inject host persistence/org context into the agent state prior to the turn.
  Must return the enriched `Tackle.Lib.State`.
  """
  @callback enrich_state(host_state(), State.t(), turn_opts()) :: State.t()

  @doc """
  Persist the user's input message for a run turn. Returns updated host state.
  """
  @callback persist_user_message(host_state(), State.t(), Tackle.Lib.Message.t()) :: host_state()

  @doc """
  Best-effort persist of an in-flight assistant message on `:message_start`.
  Returns updated host state.

  The three-argument form receives active turn correlation. The legacy
  two-argument form remains optional for Store implementations that do not need
  those options; the Runner prefers the three-argument form when both exist.
  """
  @callback persist_pending_message(host_state(), map()) :: host_state()
  @callback persist_pending_message(host_state(), map(), turn_opts()) :: host_state()

  @doc """
  Settle a finished turn: update the DB session, persist final messages, and
  apply billing for the aggregated `Tackle.Lib.Usage`. Returns updated host state.
  """
  @callback settle_turn(host_state(), turn_result(), Usage.t(), turn_opts()) :: host_state()

  @doc """
  Fire-and-forget host follow-ups after settlement (e.g. async title generation).
  Returns updated host state.
  """
  @callback after_turn(host_state(), turn_result(), turn_opts()) :: host_state()

  @doc "Returns the current persisted session id, if one exists."
  @callback current_session_id(host_state()) :: binary() | nil

  @doc """
  Handles task crashes/exits and returns
  `{updated_host_state, recovered_agent_state_or_nil}`.

  The Runner includes the aggregated provider usage collected before the crash
  under the `:turn_usage` option so hosts can settle any incurred cost.
  """
  @callback handle_turn_failed(host_state(), term(), turn_opts()) ::
              {host_state(), State.t() | nil}

  @optional_callbacks [
    init_host: 1,
    handle_host_message: 2,
    persist_pending_message: 2,
    persist_pending_message: 3,
    after_turn: 3
  ]
end

defmodule Tackle.Lib.Cancellation do
  @moduledoc """
  Cooperative cancellation primitives for Tackle.Lib runs.

  Tackle.Lib runs are synchronous from the library's point of view, but hosts often
  execute them in another process. A cancellation signal gives the host a small,
  provider-agnostic handle it can cancel from any process while the loop, LLM
  adapter, and tools cooperatively observe it.

  Cancellation is best-effort:

  * the loop checks before starting work, after LLM calls, and between tools;
  * adapters receive the signal in LLM opts and can abort provider requests;
  * tools receive the signal in their context and can stop long-running work.

  If an adapter or tool ignores the signal, Tackle.Lib cannot preempt it mid-call,
  but the loop will settle as cancelled at the next boundary.

  ## Per-call signals

  `for_call/2` derives a child signal for one tool call from a turn signal. The
  loop hands each tool its call's child signal, so a host can stop exactly one
  tool call by cancelling the child, while cancelling the turn signal still stops
  every call. A child reports its own reason first and falls back to its
  parent's. Child ids are deterministic (`{parent_id, tool_call_id}`), so any
  process holding the turn signal can derive the same child without
  coordination. Whoever cancels a child should `delete/1` it once the turn has
  settled; the loop also deletes each child after its call settles.

  ## Storage

  Cancellation storage is configurable. Tackle.Lib defaults to
  `Tackle.Lib.Cancellation.Store.Ets`, owned by a supervised process in the
  `:tackle_lib` application. Start the application before using the default store.
  Records survive caller exits, but not store owner or application restarts.
  Hosts can provide any module implementing `Tackle.Lib.Cancellation.Store`:

      config :tackle_lib, cancellation_store: MyApp.TackleCancellationStore

  """

  defmodule Signal do
    @moduledoc """
    Opaque cancellation handle shared between a host and a Tackle.Lib run.

    `parent` is set on per-call signals derived with
    `Tackle.Lib.Cancellation.for_call/2`.
    """

    @type t :: %__MODULE__{
            id: Tackle.Lib.Cancellation.Store.signal_id(),
            store: module(),
            parent: t() | nil
          }

    defstruct [:id, :store, parent: nil]
  end

  @default_store Tackle.Lib.Cancellation.Store.Ets

  @type signal :: Signal.t()
  @type reason :: term()

  @doc """
  Creates a new cancellation signal.
  """
  @spec new_signal() :: signal()
  def new_signal do
    %Signal{id: make_ref(), store: store()}
  end

  @doc """
  Derives the per-call child signal for `tool_call_id` from `signal`.

  The child shares the parent's store and has the deterministic id
  `{parent_id, tool_call_id}`, so deriving it twice yields equal signals.
  Cancelling the child does not cancel the parent; cancelling the parent is
  observed through the child. Returns `nil` when `signal` is `nil`.
  """
  @spec for_call(signal() | nil, term()) :: signal() | nil
  def for_call(nil, _tool_call_id), do: nil

  def for_call(%Signal{id: id} = signal, tool_call_id) do
    %Signal{id: {id, tool_call_id}, store: signal_store(signal), parent: signal}
  end

  @doc """
  Marks a signal as cancelled.
  """
  @spec cancel(signal(), reason()) :: :ok
  def cancel(%Signal{id: id} = signal, reason \\ :cancelled) do
    signal_store(signal).cancel(id, reason)
  end

  @doc """
  Returns true when the signal has been cancelled.
  """
  @spec cancelled?(signal() | nil) :: boolean()
  def cancelled?(nil), do: false

  def cancelled?(%Signal{} = signal) do
    reason(signal) != nil
  end

  @doc """
  Returns the cancellation reason, or nil when the signal is still active.

  A per-call signal returns its own reason when it was cancelled directly and
  otherwise its parent's reason.
  """
  @spec reason(signal() | nil) :: reason() | nil
  def reason(nil), do: nil

  def reason(%Signal{id: id, parent: parent} = signal) do
    case signal_store(signal).reason(id) do
      nil -> reason(parent)
      reason -> reason
    end
  end

  @doc """
  Removes a signal from the cancellation table.

  Hosts may call this after a run is fully settled if they create many signals.
  Deleting a per-call signal removes only its own record, never its parent's.
  """
  @spec delete(signal() | nil) :: :ok
  def delete(nil), do: :ok

  def delete(%Signal{id: id} = signal) do
    signal_store(signal).delete(id)
  end

  defp signal_store(%Signal{store: store}) when is_atom(store) and not is_nil(store), do: store
  defp signal_store(%Signal{}), do: store()

  defp store do
    Application.get_env(:tackle_lib, :cancellation_store) || @default_store
  end
end

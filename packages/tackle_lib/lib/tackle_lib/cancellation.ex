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

  ## Storage

  Cancellation storage is configurable. Tackle.Lib defaults to
  `Tackle.Lib.Cancellation.Store.Ets` to preserve historical cross-process behavior,
  but hosts can provide any module implementing `Tackle.Lib.Cancellation.Store`:

      config :tackle_lib, cancellation_store: MyApp.TackleCancellationStore

  """

  defmodule Signal do
    @moduledoc """
    Opaque cancellation handle shared between a host and a Tackle.Lib run.
    """

    @type t :: %__MODULE__{id: reference(), store: module()}

    defstruct [:id, :store]
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
  """
  @spec reason(signal() | nil) :: reason() | nil
  def reason(nil), do: nil

  def reason(%Signal{id: id} = signal) do
    signal_store(signal).reason(id)
  end

  @doc """
  Removes a signal from the cancellation table.

  Hosts may call this after a run is fully settled if they create many signals.
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

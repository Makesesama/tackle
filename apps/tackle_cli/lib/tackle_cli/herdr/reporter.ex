defmodule Tackle.CLI.Herdr.Reporter do
  @moduledoc """
  Sends the shell's Herdr reports without blocking the shell.

  The shell casts the state it wants Herdr to show; the reporter sends it over
  the socket from its own process, so a slow or missing Herdr server never
  stalls a frame. Only the latest state matters: when several reports queue up
  while one is in flight, the older ones are dropped, as Herdr's integration
  guide asks. Each report carries a fresh sequence assigned when it is sent,
  so reports reach Herdr in order and a late one cannot overwrite newer state.

  `release/2` is synchronous because it runs while the shell exits: it drops
  any queued report, tells Herdr the agent left the pane before the VM can
  halt, and stops the reporter. Send failures, including a sender that raises,
  are ignored; Herdr also clears a pane on its own once it is back at an idle
  shell prompt.
  """

  use GenServer

  alias Tackle.CLI.Herdr

  # A release can wait behind one report in flight, and each request is
  # bounded by `Tackle.CLI.Herdr.send_request/3`'s 500 ms deadline.
  @release_timeout 1_200

  @typedoc "Sends one request to Herdr; injected by tests."
  @type sender :: (Herdr.config(), Herdr.request() -> :ok | {:error, term()})

  @doc """
  Starts a reporter for the pane in `config`, linked to the caller.

  Options: `:sender` replaces the socket transport.
  """
  @spec start_link(Herdr.config(), keyword()) :: GenServer.on_start()
  def start_link(config, opts \\ []) do
    GenServer.start_link(__MODULE__, {config, Keyword.get(opts, :sender, &Herdr.send_request/2)})
  end

  @doc "Asks the reporter to send `report`, replacing any report still queued."
  @spec report(pid(), Herdr.report()) :: :ok
  def report(reporter, report), do: GenServer.cast(reporter, {:report, report})

  @doc """
  Drops any queued report, releases the pane, and stops the reporter, waiting
  at most `timeout`.

  Returns `:ok` even when the reporter is gone or Herdr does not answer in
  time, because the shell's exit must not depend on Herdr.
  """
  @spec release(pid(), timeout()) :: :ok
  def release(reporter, timeout \\ @release_timeout) do
    GenServer.call(reporter, :release, timeout)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init({config, sender}) do
    {:ok, %{config: config, sender: sender, seq: 0, pending: nil, flush_scheduled?: false}}
  end

  @impl true
  def handle_cast({:report, report}, state) do
    state = %{state | pending: report}

    if state.flush_scheduled? do
      {:noreply, state}
    else
      send(self(), :flush)
      {:noreply, %{state | flush_scheduled?: true}}
    end
  end

  # The flush runs after every report already in the mailbox has replaced
  # `pending`, so a burst of state changes sends only its last state.
  @impl true
  def handle_info(:flush, %{pending: nil} = state),
    do: {:noreply, %{state | flush_scheduled?: false}}

  def handle_info(:flush, %{pending: report} = state) do
    seq = Herdr.next_seq(state.seq)
    _result = deliver(state, Herdr.report_request(state.config, report, seq))
    {:noreply, %{state | seq: seq, pending: nil, flush_scheduled?: false}}
  end

  @impl true
  def handle_call(:release, _from, state) do
    seq = Herdr.next_seq(state.seq)
    _result = deliver(state, Herdr.release_request(state.config, seq))
    {:stop, :normal, :ok, %{state | seq: seq, pending: nil}}
  end

  # Reporting is best effort, so a failing sender must not take the reporter
  # down with it and silence every later report.
  defp deliver(state, request) do
    state.sender.(state.config, request)
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end

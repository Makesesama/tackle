defmodule Tackle.Web.ReviewJob.Lifecycle do
  @moduledoc false
  use GenServer
  require Logger

  alias Tackle.Runtime
  alias Tackle.Runtime.{ID, ScopeRef}
  alias Tackle.Web.{Checkout, ReviewJail}

  # This unlinked owner monitors the Oban caller. All resource acquisition is
  # serialized here: a DOWN during start_scope/prepare is processed only after
  # acquisition returns, so there is no unregistered-resource orphan window.
  # It also keeps Checkout's preparing process/lease alive through cleanup.
  def start(caller, opts), do: GenServer.start(__MODULE__, {caller, opts})
  def prepare(owner, request), do: GenServer.call(owner, {:prepare, request}, :infinity)
  def jail(owner, checkout), do: GenServer.call(owner, {:jail, checkout}, :infinity)
  def scope(owner, spec), do: GenServer.call(owner, {:scope, spec}, :infinity)
  def check(owner), do: GenServer.call(owner, :check)

  def stop(owner) do
    ref = Process.monitor(owner)

    try do
      result = GenServer.call(owner, :stop, :infinity)
      receive do: ({:DOWN, ^ref, :process, ^owner, _reason} -> result)
    catch
      :exit, {:noproc, _call} -> :ok
      :exit, _reason -> {:error, :review_cleanup_failed}
    after
      Process.demonitor(ref, [:flush])
    end
  end

  @impl true
  def init({caller, opts}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       monitor: Process.monitor(caller),
       checkout: nil,
       jail: nil,
       client_monitor: nil,
       cleaned: false,
       scope: ScopeRef.new!(ID.generate()),
       checkout_module: Keyword.get(opts, :checkout, Checkout),
       checkout_opts: Keyword.get(opts, :checkout_opts, []),
       jail_module: Keyword.get(opts, :jail, ReviewJail)
     }}
  end

  @impl true
  def handle_call({:prepare, request}, _from, state) do
    result = state.checkout_module.prepare(request, state.checkout_opts)
    {:reply, result, remember(state, :checkout, result)}
  end

  def handle_call({:jail, checkout}, _from, state) do
    result = state.jail_module.start(checkout)
    state = remember(state, :jail, result)

    case result do
      {:ok, %{client: client, supervisor: supervisor}}
      when is_pid(client) and is_pid(supervisor) ->
        {:reply, result, %{state | client_monitor: Process.monitor(client)}}

      {:ok, _invalid} ->
        {:reply, {:error, :review_runtime_stopped}, state}

      _error ->
        {:reply, result, state}
    end
  end

  def handle_call({:scope, spec}, _from, state) do
    {:reply, Runtime.start_scope(%{spec | scope_ref: state.scope}), state}
  end

  def handle_call(:check, _from, state) do
    result =
      with %{client: client, supervisor: supervisor} <- state.jail,
           true <- is_pid(client) and Process.alive?(client),
           true <- is_pid(supervisor) and Process.alive?(supervisor),
           {:ok, _snapshot} <- Runtime.scope_snapshot(state.scope) do
        :ok
      else
        _stopped -> {:error, :review_runtime_stopped}
      end

    {:reply, result, state}
  end

  def handle_call(:stop, _from, state) do
    result = cleanup(state)
    {:stop, :normal, result, %{state | cleaned: true}}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{client_monitor: monitor} = state),
    do: {:stop, :normal, state}

  def handle_info({:EXIT, pid, _reason}, %{jail: %{supervisor: pid}} = state),
    do: {:stop, :normal, state}

  # Host Git ports (and failed jail startup probes) can leave normal EXIT
  # signals in this trapping owner. Only the acquired jail owns its lifecycle.
  def handle_info({:EXIT, _source, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{cleaned: true}), do: :ok
  def terminate(_reason, state), do: cleanup(state)

  defp cleanup(state) do
    # Evaluate every stage even after an error. Never log exception messages,
    # arbitrary return values, checkout paths, or provider/forge credentials.
    results = [
      safely(:scope, fn -> Runtime.stop_scope(state.scope) end),
      safely(:jail, fn -> if state.jail, do: state.jail_module.stop(state.jail), else: :ok end),
      safely(:checkout, fn ->
        if state.checkout,
          do: state.checkout_module.cleanup(state.checkout, state.checkout_opts),
          else: :ok
      end)
    ]

    if Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:error, :review_cleanup_failed}
  end

  defp remember(state, key, {:ok, resource}), do: Map.put(state, key, resource)
  defp remember(state, _key, _error), do: state

  defp safely(stage, fun) do
    case fun.() do
      :ok -> :ok
      {:error, :not_found} when stage == :scope -> :ok
      _other -> cleanup_failed(stage)
    end
  catch
    _kind, _reason -> cleanup_failed(stage)
  end

  defp cleanup_failed(stage) do
    Logger.warning("Review cleanup failed at stage: #{stage}")
    {:error, :review_cleanup_failed}
  end
end

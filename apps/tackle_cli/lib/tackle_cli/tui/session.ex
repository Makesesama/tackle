defmodule Tackle.CLI.TUI.Session do
  @moduledoc """
  Ownership of the root scope the shell is attached to.

  The shell owns exactly one scope at a time. Starting a new session asks the
  frontend for a fresh root scope, subscribes to it, and only then retires the
  old one, so a failed adoption leaves the running session untouched. When the
  replacement subscribes but cannot be monitored, the already-running
  replacement scope is stopped rather than leaked.

  `retire/1` is the single teardown path: it flushes the agent monitor,
  unsubscribes, and stops the scope, swallowing an exit from a scope that has
  already gone down. The shell calls it on termination and on every adoption,
  and it is also what guarantees a swapped-in scope cannot outlive the process.
  """

  alias Tackle.CLI.TUI.{State, Util}
  alias Tackle.Runtime.Scope
  alias Tackle.Session.Snapshot
  alias Tackle.Thinking

  @doc """
  Asks for confirmation before starting a new session.

  Confirmation exists because adopting a fresh scope stops the current one,
  taking any active turn and delegated work with it. Durable history is not
  deleted; the shell simply moves on to a new, empty session. A frontend that
  cannot start sessions says so instead of opening an inert prompt.
  """
  @spec request_new(State.t()) :: {:noreply, State.t()}
  def request_new(%State{new_session: nil} = state) do
    {:noreply, %{state | notice: "New session is unavailable in this frontend"}}
  end

  def request_new(%State{} = state) do
    reason = if state.active_turn, do: :turn, else: :idle
    {:noreply, %{state | overlay: {:confirm_new_session, %{reason: reason}}}}
  end

  @doc """
  Starts the replacement session, carrying the current model and reasoning
  level over as overrides.
  """
  @spec start_new(State.t()) :: {:noreply, State.t()}
  def start_new(%State{} = state) do
    overrides = %{
      model: State.model_ref(state.agent_state),
      thinking: Thinking.from_llm_opts(state.agent_state.llm_opts)
    }

    case state.new_session.(overrides) do
      {:ok, %Scope{} = scope} ->
        adopt(state, scope)

      {:error, reason} ->
        {:noreply, %{state | overlay: nil, error: Util.format_reason(reason)}}

      other ->
        {:noreply,
         %{state | overlay: nil, error: Util.format_reason({:invalid_new_session, other})}}
    end
  end

  @doc """
  Subscribes to a replacement scope and adopts it.

  The old scope is retired only after the replacement has been subscribed and
  monitored, so a failure here cannot take down the session the user is in.
  """
  @spec adopt(State.t(), Scope.t()) :: {:noreply, State.t()}
  def adopt(%State{} = state, %Scope{} = scope) do
    with {:ok, %Snapshot{} = snapshot} <- Tackle.subscribe(scope.root_agent_ref),
         {:ok, monitor} <- Tackle.monitor_agent(scope.root_agent_ref) do
      retire(state)
      {:noreply, State.reset(state, scope, snapshot, monitor)}
    else
      {:error, reason} ->
        shutdown(scope.scope_ref)
        {:noreply, %{state | overlay: nil, error: Util.format_reason(reason)}}
    end
  end

  @doc """
  Detaches from the current session and stops its scope.

  Safe to call more than once: a monitor that was already flushed, an
  unsubscribed agent, and a scope that is already down are all no-ops.
  """
  @spec retire(State.t()) :: :ok
  def retire(%State{} = state) do
    if is_reference(state.agent_monitor), do: Process.demonitor(state.agent_monitor, [:flush])
    _ = if state.agent_ref, do: Tackle.unsubscribe(state.agent_ref)
    shutdown(state.scope_ref)
    :ok
  end

  @doc "Stops a scope by reference, tolerating a scope that has already exited."
  @spec shutdown(term()) :: :ok
  def shutdown(nil), do: :ok

  def shutdown(scope_ref) do
    _ = Tackle.stop_scope(scope_ref)
    :ok
  catch
    :exit, _reason -> :ok
  end
end

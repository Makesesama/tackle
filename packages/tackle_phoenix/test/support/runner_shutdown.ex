defmodule Tackle.Phoenix.RunnerShutdownAgent do
  @moduledoc false

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.State

  def continue(%State{} = state, opts) do
    signal = Keyword.fetch!(opts, :cancellation_signal)
    test_pid = state.context.test_pid

    send(test_pid, {:runner_shutdown_agent_started, self(), signal})
    await_cancellation(state, signal, test_pid)
  end

  defp await_cancellation(state, signal, test_pid) do
    if Cancellation.cancelled?(signal) do
      send(test_pid, {:runner_shutdown_agent_cancelled, self()})
      {:cancelled, state}
    else
      receive do
      after
        10 -> await_cancellation(state, signal, test_pid)
      end
    end
  end
end

defmodule Tackle.Phoenix.RunnerShutdownStore do
  @moduledoc false
  @behaviour Tackle.Phoenix.Store

  alias Tackle.Lib.State

  @impl true
  def before_turn(_host_state, _opts), do: :ok

  @impl true
  def enrich_state(host_state, agent_state, opts) do
    session_id = Keyword.get(opts, :session_id) || current_session_id(host_state)

    context =
      agent_state.context
      |> Map.put_new(:persistence, %{})
      |> update_in([:persistence], &Map.put(&1, :session_id, session_id))

    %{agent_state | context: context}
  end

  @impl true
  def persist_user_message(_host_state, agent_state, _message), do: agent_state

  @impl true
  def settle_turn(host_state, _result, _usage, _opts), do: host_state

  @impl true
  def after_turn(host_state, _result, _opts), do: host_state

  @impl true
  def current_session_id(%State{} = agent_state),
    do: get_in(agent_state.context, [:persistence, :session_id])

  def current_session_id(%{session_id: session_id}), do: session_id

  def current_session_id(_host_state), do: nil

  @impl true
  def handle_turn_failed(host_state, _reason, _opts), do: {host_state, nil}
end

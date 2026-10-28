defmodule Tackle.AgentService do
  @moduledoc false

  # Plumbing shared by the agent services `Tackle.Watchdog` and
  # `Tackle.Narrator`: GenServers registered beside one agent under its
  # `Tackle.Runtime.ServiceSupervisor`, which subscribe to the agent's session,
  # follow its tool calls, and run one model call at a time
  # (`Tackle.AgentService.Call`) on a single timer. Functions only; each
  # service owns its process and state.

  require Logger

  alias Tackle.Runtime
  alias Tackle.Runtime.{AgentRef, Registry}

  @subscribe_retry_ms 1_000

  @typedoc "A pending timer and the monotonic time it fires at."
  @type timer :: {reference(), integer()} | nil

  @doc "Events that end a tool call."
  defguard is_tool_call_end(type) when type in [:tool_execution_end, :tool_end, :tool_error]

  @doc "Starts `module` registered as the service of `opts[:agent_ref]`."
  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(module, opts) do
    agent_ref = Keyword.fetch!(opts, :agent_ref)
    GenServer.start_link(module, opts, name: Registry.service_name(agent_ref, module))
  end

  @doc "Whether the service `module` is running for `agent_ref`."
  @spec running?(AgentRef.t(), module()) :: boolean()
  def running?(%AgentRef{} = agent_ref, module),
    do: match?({:ok, _pid}, Registry.service(agent_ref, module))

  @doc """
  Reads the `:request_timeout` start option, the milliseconds a model request
  may take, or `default`; raises `ArgumentError` unless it is a positive
  integer.
  """
  @spec request_timeout!(keyword(), pos_integer()) :: pos_integer()
  def request_timeout!(opts, default) do
    case Keyword.get(opts, :request_timeout, default) do
      timeout when is_integer(timeout) and timeout > 0 ->
        timeout

      other ->
        raise ArgumentError,
              "expected :request_timeout to be a positive integer, got: #{inspect(other)}"
    end
  end

  @doc """
  Subscribes the calling service to its agent's session.

  A session refuses subscriptions during a turn, which happens when a service
  restarts mid-turn; the caller then receives `:subscribe` after a second and
  calls this again.
  """
  @spec subscribe(AgentRef.t()) :: :ok | {:error, term()}
  def subscribe(%AgentRef{} = agent_ref) do
    case Runtime.subscribe(agent_ref) do
      {:ok, _snapshot} ->
        :ok

      :ok ->
        :ok

      {:error, :turn_in_progress} ->
        Process.send_after(self(), :subscribe, @subscribe_retry_ms)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Logs `message` as a warning unless the state already `warned?`, so a
  failing model is reported once.
  """
  @spec warn_once(%{warned?: boolean()}, String.t()) :: %{warned?: true}
  def warn_once(%{warned?: true} = state, _message), do: state

  def warn_once(%{warned?: false} = state, message) do
    Logger.warning(message)
    %{state | warned?: true}
  end

  @doc """
  Sets the service's timer to send `message` at the monotonic time `at`.

  An unchanged due time keeps its timer, so frequent events do not churn
  timers; `:infinity` cancels it.
  """
  @spec schedule(timer(), integer() | :infinity, term()) :: timer()
  def schedule(timer, :infinity, _message), do: cancel(timer)
  def schedule({_ref, at} = timer, at, _message), do: timer

  def schedule(timer, at, message) when is_integer(at) do
    cancel(timer)
    {Process.send_after(self(), message, max(at - now(), 0)), at}
  end

  @doc "Cancels the service's timer."
  @spec cancel(timer()) :: nil
  def cancel(nil), do: nil

  def cancel({ref, _at}) do
    Process.cancel_timer(ref)
    nil
  end

  @doc """
  Reads a tool-call argument. Provider arguments are decoded JSON with string
  keys; hosts that build calls by hand may use atom keys.
  """
  @spec argument(map(), String.t(), atom()) :: term()
  def argument(arguments, key, atom_key) when is_map(arguments),
    do: Map.get(arguments, key, Map.get(arguments, atom_key))

  @doc "The monotonic time in milliseconds that services schedule by."
  @spec now() :: integer()
  def now, do: System.monotonic_time(:millisecond)
end

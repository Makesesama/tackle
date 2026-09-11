defmodule Tackle.Session.Supervisor do
  @moduledoc """
  Per-agent-session supervisor owning one session and its tool supervisor.

  Every `Tackle.Session` runs beneath one of these so concurrent tool execution
  has a dedicated, session-local `Task.Supervisor`:

      Tackle.Session.Supervisor
      ├── Task.Supervisor   — tool tasks for this session only
      └── Tackle.Session    — the agent session

  There is one supervisor per agent, so a subagent — itself an ordinary session —
  never shares a tool supervisor with its parent. Terminating the subtree cleans
  up every in-flight tool task for exactly one agent.

  The supervisor is deliberately `:one_for_all` with `max_restarts: 0`: the tool
  supervisor and the session are both scope-critical, so any child exit tears the
  subtree down and lets the owning supervisor (the `AgentScope` for the root, the
  scope work supervisor for descendants) apply its policy. An empty session is
  never reconstructed, and an ephemeral session cleans up its tool supervisor as
  part of the same unit.

  The tool supervisor is registered as `{:tool_supervisor, scope_id, agent_id}` so
  it stays discoverable without dynamic atom generation.
  """

  use Supervisor

  alias Tackle.Config
  alias Tackle.Runtime.Registry

  @doc false
  @spec start_link({Config.t(), keyword()}) :: Supervisor.on_start()
  def start_link({%Config{}, _opts} = arg), do: Supervisor.start_link(__MODULE__, arg)

  @doc false
  def child_spec({%Config{}, opts} = arg) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [arg]},
      restart: Keyword.get(opts, :restart, :temporary),
      type: :supervisor
    }
  end

  @impl true
  def init({%Config{} = config, opts}) do
    agent_ref = Keyword.fetch!(opts, :agent_ref)
    tool_supervisor = Registry.tool_supervisor_name(agent_ref)
    session_opts = Keyword.put(opts, :tool_supervisor, tool_supervisor)

    # The session is permanent so that any exit — normal or abnormal — reaches the
    # supervisor's restart logic. With `max_restarts: 0` that tears this subtree
    # down, which is how an ephemeral session also cleans up its tool supervisor.
    session_child =
      Supervisor.child_spec({Tackle.Session, {config, session_opts}}, restart: :permanent)

    children = [
      {Task.Supervisor, name: tool_supervisor},
      session_child
    ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0, max_seconds: 1)
  end

  @doc "Returns the `Tackle.Session` pid inside a session supervisor, or nil."
  @spec session_pid(Supervisor.supervisor()) :: pid() | nil
  def session_pid(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {_id, pid, :worker, modules} when is_pid(pid) ->
        if Tackle.Session in modules, do: pid

      _child ->
        nil
    end)
  end
end

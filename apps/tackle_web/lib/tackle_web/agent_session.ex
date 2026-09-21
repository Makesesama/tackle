defmodule Tackle.Web.AgentSession do
  @moduledoc """
  Wires one review's conversation to a `Tackle.Phoenix.Runner`.

  LiveViews talk to this module rather than to `Tackle.Phoenix.Runner`, so the
  infrastructure names (`Registry`, supervisors, PubSub, store) stay in one
  place, and so does the conversation transcript: every entry point reloads it,
  which is what lets a Runner be recreated after its idle timeout without losing
  the conversation.

  A conversation is keyed by the project's slug and the review id, so every
  viewer of the same review shares one conversation and one agent. That is the
  point — a reviewer asks a question and the answer is already sitting there for
  the next person — and it is why the same code serves a GitHub pull request and
  a local ref range.

  Every function takes a *loaded review*, the map
  `Tackle.Web.Projects.load_review/2` returns. It already carries the project,
  the review id, the refs and the checkout, so nothing here has to know where the
  code came from.
  """

  alias Tackle.Lib.State
  alias Tackle.Phoenix.Runner
  alias Tackle.Web.Agent
  alias Tackle.Web.AgentConversation
  alias Tackle.Web.AgentStore
  alias Tackle.Web.Project.Source

  @config %{
    registry: Tackle.Web.AgentRegistry,
    dynamic_supervisor: Tackle.Web.AgentSupervisor,
    task_supervisor: Tackle.Web.AgentTaskSupervisor,
    pubsub: Tackle.Web.PubSub,
    store: AgentStore,
    agent: Agent
  }

  @typedoc """
  A conversation's current state.

    * `:agent_state` — the `Tackle.Lib.State` a LiveView renders from.
    * `:anchors` — which line each question was asked about, by message id.
    * `:turn_active?` — whether a turn is running.
    * `:runner_pid` — the Runner to cancel, while a turn is active.
  """
  @type snapshot :: %{
          agent_state: State.t(),
          anchors: %{optional(String.t()) => term()},
          session_id: String.t() | nil,
          turn_active?: boolean(),
          runner_pid: pid() | nil
        }

  @doc """
  Subscribes the caller to the conversation's turn events.

  Keyed by the project and review rather than by a loaded review, so a viewer can
  subscribe as soon as the page mounts — before, and independently of, the clone
  a first load may have to make.
  """
  @spec subscribe(String.t(), String.t()) :: :ok | {:error, term()}
  def subscribe(slug, review_id),
    do: Runner.subscribe(@config, AgentConversation.key(slug, review_id), nil)

  @doc """
  Reads the conversation atomically: agent state, anchors, and active turn.

  Building the agent state here means a Runner recreated after its idle timeout
  resumes the stored conversation instead of starting an empty one.

  Returns `{:error, reason}` when the agent cannot be built at all — an unknown
  model reference, for instance.
  """
  @spec snapshot(Source.loaded_review(), keyword()) :: {:ok, snapshot()} | {:error, term()}
  def snapshot(loaded, opts \\ []) do
    transcript = AgentConversation.load(transcript_path(loaded))

    with {:ok, agent_state} <-
           Agent.new(loaded, model: Keyword.get(opts, :model), messages: transcript.messages),
         %{} = snapshot <- start_and_snapshot(loaded, agent_state, transcript.anchors) do
      {:ok, Map.put(snapshot, :anchors, transcript.anchors)}
    end
  end

  # `Runner.get_or_start/3` looks the Runner up in a Registry and starts one if it
  # is absent, so two viewers opening the same review at once can both see it as
  # absent. The loser is told the process is already started and simply has to
  # ask again, now that the Registry knows about it.
  defp start_and_snapshot(loaded, agent_state, anchors) do
    opts = [agent_state: agent_state, host_state: host_state(loaded, anchors)]

    case Runner.snapshot(@config, key(loaded), opts) do
      {:error, {:already_started, _pid}} -> Runner.snapshot(@config, key(loaded), opts)
      result -> result
    end
  end

  @doc """
  Asks the assistant a question, appending it to the conversation.

  `opts[:anchor]` records what the question was asked about, and
  `opts[:anchors]` carries the anchors already known so a Runner started for
  this turn inherits them.
  """
  @spec run_turn(Source.loaded_review(), State.t(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def run_turn(loaded, %State{} = state, input, opts \\ []) do
    Runner.run_turn(
      @config,
      key(loaded),
      anchored(state, Keyword.get(opts, :anchor)),
      input,
      runner_opts(loaded, opts)
    )
  end

  @doc "Retries the last question without appending a new one."
  @spec continue_turn(Source.loaded_review(), State.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def continue_turn(loaded, %State{} = state, opts \\ []) do
    Runner.continue_turn(
      @config,
      key(loaded),
      anchored(state, Keyword.get(opts, :anchor)),
      runner_opts(loaded, opts)
    )
  end

  @doc "Requests cooperative cancellation of the running turn."
  @spec cancel_turn(pid() | nil) :: :ok
  def cancel_turn(pid), do: Runner.cancel_turn(pid)

  @doc "The path of the conversation's stored transcript."
  @spec transcript_path(Source.loaded_review()) :: Path.t()
  def transcript_path(%{project: project, review_id: review_id}) do
    AgentConversation.path(project.slug, review_id)
  end

  # The anchor of the question being asked right now belongs on the agent state,
  # not the Runner's host state: the Runner keeps the host state it was started
  # with, while this state is the caller's and is rebuilt for every turn.
  defp anchored(%State{} = state, anchor) do
    turn = state.context |> Map.get(:turn, %{}) |> Map.put(:anchor, anchor)

    %{state | context: Map.put(state.context, :turn, turn)}
  end

  defp runner_opts(loaded, opts) do
    [
      host_state: host_state(loaded, Keyword.get(opts, :anchors, %{})),
      telemetry_metadata: telemetry_metadata(loaded)
    ]
  end

  defp host_state(loaded, anchors), do: %{loaded: loaded, anchors: anchors}

  # Bounded and non-secret, per the Runner's telemetry contract.
  defp telemetry_metadata(%{project: project, review_id: review_id}) do
    %{source: :review, project: project.slug, review: review_id}
  end

  defp key(%{project: project, review_id: review_id}) do
    AgentConversation.key(project.slug, review_id)
  end
end

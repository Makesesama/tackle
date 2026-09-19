defmodule Tackle.Web.AgentSession do
  @moduledoc """
  Wires one pull request's conversation to a `Tackle.Phoenix.Runner`.

  LiveViews talk to this module rather than to `Tackle.Phoenix.Runner`, so the
  infrastructure names (`Registry`, supervisors, PubSub, store) stay in one
  place, and so does the conversation transcript: every entry point reloads it,
  which is what lets a Runner be recreated after its idle timeout without losing
  the conversation.

  A conversation is keyed by `owner/repo#number`, so every viewer of a pull
  request shares one conversation and one agent. That is the point — a reviewer
  asks a question and the answer is already sitting there for the next person.
  """

  alias Tackle.Lib.State
  alias Tackle.Phoenix.Runner
  alias Tackle.Web.Agent
  alias Tackle.Web.AgentConversation
  alias Tackle.Web.AgentStore

  @config %{
    registry: Tackle.Web.AgentRegistry,
    dynamic_supervisor: Tackle.Web.AgentSupervisor,
    task_supervisor: Tackle.Web.AgentTaskSupervisor,
    pubsub: Tackle.Web.PubSub,
    store: AgentStore,
    agent: Agent
  }

  @typedoc "A pull request, as the assistant and the transcript identify it."
  @type review :: %{
          owner: String.t(),
          repo: String.t(),
          number: pos_integer(),
          title: String.t() | nil,
          base_ref: String.t() | nil,
          head_ref: String.t() | nil
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

  @doc "Subscribes the caller to the conversation's turn events."
  @spec subscribe(review()) :: :ok | {:error, term()}
  def subscribe(%{owner: owner, repo: repo, number: number}) do
    Runner.subscribe(@config, AgentConversation.key(owner, repo, number), nil)
  end

  @doc """
  Reads the conversation atomically: agent state, anchors, and active turn.

  Building the agent state here means a Runner recreated after its idle timeout
  resumes the stored conversation instead of starting an empty one.

  Returns `{:error, reason}` when the agent cannot be built at all — an unknown
  model reference, for instance.
  """
  @spec snapshot(review(), Path.t(), keyword()) :: {:ok, snapshot()} | {:error, term()}
  def snapshot(review, cwd, opts \\ []) do
    transcript = AgentConversation.load(transcript_path(review))

    with {:ok, agent_state} <-
           Agent.new(
             cwd: cwd,
             review: review,
             model: Keyword.get(opts, :model),
             messages: transcript.messages
           ),
         %{} = snapshot <- start_and_snapshot(review, agent_state, cwd, transcript.anchors) do
      {:ok, Map.put(snapshot, :anchors, transcript.anchors)}
    end
  end

  # `Runner.get_or_start/3` looks the Runner up in a Registry and starts one if it
  # is absent, so two viewers opening the same pull request at once can both see
  # it as absent. The loser is told the process is already started and simply has
  # to ask again, now that the Registry knows about it.
  defp start_and_snapshot(review, agent_state, cwd, anchors) do
    opts = [agent_state: agent_state, host_state: host_state(review, cwd, anchors)]

    case Runner.snapshot(@config, key(review), opts) do
      {:error, {:already_started, _pid}} -> Runner.snapshot(@config, key(review), opts)
      result -> result
    end
  end

  @doc """
  Asks the assistant a question, appending it to the conversation.

  `opts[:anchor]` records what the question was asked about, and
  `opts[:anchors]` carries the anchors already known so a Runner started for
  this turn inherits them.
  """
  @spec run_turn(review(), Path.t(), State.t(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def run_turn(review, cwd, %State{} = state, input, opts \\ []) do
    Runner.run_turn(
      @config,
      key(review),
      anchored(state, Keyword.get(opts, :anchor)),
      input,
      runner_opts(review, cwd, opts)
    )
  end

  @doc "Retries the last question without appending a new one."
  @spec continue_turn(review(), Path.t(), State.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def continue_turn(review, cwd, %State{} = state, opts \\ []) do
    Runner.continue_turn(
      @config,
      key(review),
      anchored(state, Keyword.get(opts, :anchor)),
      runner_opts(review, cwd, opts)
    )
  end

  @doc "Requests cooperative cancellation of the running turn."
  @spec cancel_turn(pid() | nil) :: :ok
  def cancel_turn(pid), do: Runner.cancel_turn(pid)

  @doc "The path of the conversation's stored transcript."
  @spec transcript_path(review()) :: Path.t()
  def transcript_path(%{owner: owner, repo: repo, number: number}) do
    AgentConversation.path(owner, repo, number)
  end

  # The anchor of the question being asked right now belongs on the agent state,
  # not the Runner's host state: the Runner keeps the host state it was started
  # with, while this state is the caller's and is rebuilt for every turn.
  defp anchored(%State{} = state, anchor) do
    turn = state.context |> Map.get(:turn, %{}) |> Map.put(:anchor, anchor)

    %{state | context: Map.put(state.context, :turn, turn)}
  end

  defp runner_opts(review, cwd, opts) do
    [
      host_state: host_state(review, cwd, Keyword.get(opts, :anchors, %{})),
      telemetry_metadata: telemetry_metadata(review)
    ]
  end

  defp host_state(review, cwd, anchors) do
    %{review: review, cwd: cwd, anchors: anchors}
  end

  # Bounded and non-secret, per the Runner's telemetry contract.
  defp telemetry_metadata(%{owner: owner, repo: repo, number: number}) do
    %{source: :review, repository: "#{owner}/#{repo}", pull_request: number}
  end

  defp key(%{owner: owner, repo: repo, number: number}) do
    AgentConversation.key(owner, repo, number)
  end
end

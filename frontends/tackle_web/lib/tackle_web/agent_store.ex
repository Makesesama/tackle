defmodule Tackle.Web.AgentStore do
  @moduledoc """
  Host side of `Tackle.Phoenix.Runner` for review conversations.

  The Store is the seam the Runner expects the host to own: authorization,
  enrichment, persistence and settlement. This host is a single-tenant review
  board with no accounts, so most of those phases have nothing to do. What is
  left is real:

    * `enrich_state/3` pins the conversation to one review and its checkout. The
      Runner treats the agent's context as opaque, so this is the only place that
      decides which repository the assistant may read.
    * `before_turn/2` fails closed when that checkout has gone away, rather than
      letting the model start a turn whose every tool call would fail.
    * `persist_user_message/3` records which line the question was asked about.
      The anchor cannot live in the Runner's host state, because the Runner
      keeps the host state it was started with; it arrives on the agent state's
      context, which the caller owns per turn.
    * `settle_turn/4` writes the transcript, including for failed and cancelled
      turns, so a half-finished exchange is not silently lost.
    * `current_session_id/1` returns `nil` deliberately. The Runner then
      broadcasts on one stable per-conversation topic instead of switching to a
      session topic mid-turn, which keeps every viewer in step without relying on
      the dual-topic fan-out.

  Host state is `%{loaded: loaded_review, anchors: %{message_id => anchor}}`,
  where `loaded_review` is what `Tackle.Web.Projects.load_review/2` returned: the
  project, the review id, the refs and the checkout. Keeping that one map whole
  is what lets the same store serve a GitHub pull request and a local diff.
  """

  @behaviour Tackle.Phoenix.Store

  require Logger

  alias Tackle.Lib.State
  alias Tackle.Web.AgentConversation

  @typedoc "Opaque Runner state: the loaded review and the question anchors."
  @type host_state :: %{
          loaded: Tackle.Web.Project.Source.loaded_review(),
          anchors: %{optional(String.t()) => term()}
        }

  @impl true
  def before_turn(%{loaded: %{cwd: cwd}}, _opts) do
    if is_binary(cwd) and File.dir?(cwd) do
      :ok
    else
      {:error, {:checkout_missing, cwd}}
    end
  end

  @impl true
  def enrich_state(%{loaded: loaded}, %State{} = state, opts) do
    turn =
      state.context
      |> Map.get(:turn, %{})
      |> Map.put_new(:metadata, Keyword.get(opts, :turn_metadata, %{}))

    # `:persistence` has to exist as a map: the Runner records that it persisted
    # the user message by updating `context.persistence.persisted_ids`, and
    # `update_in/3` does not create intermediate keys. This host persists nothing
    # per message, so the map stays empty.
    context =
      state.context
      |> Map.put_new(:persistence, %{})
      |> Map.merge(context_of(loaded))
      |> Map.put(:turn, turn)

    %{state | context: context}
  end

  @impl true
  def persist_user_message(%{anchors: anchors} = host_state, %State{} = state, message) do
    case anchor_of(state) do
      nil ->
        host_state

      anchor ->
        broadcast(host_state, {:agent_anchor, message.id, anchor})
        %{host_state | anchors: Map.put(anchors, message.id, anchor)}
    end
  end

  def persist_user_message(host_state, _state, _message), do: host_state

  @impl true
  def settle_turn(host_state, result, _usage, _opts) do
    case result do
      {_status, %State{} = state} -> persist(host_state, state)
      _other -> host_state
    end
  end

  @impl true
  def current_session_id(_host_state), do: nil

  @impl true
  def handle_turn_failed(host_state, _reason, _opts), do: {host_state, nil}

  # Declared optional by `Tackle.Phoenix.Store`, but `Tackle.Phoenix.Runner` calls
  # it unconditionally, so a host that leaves it out crashes every turn. This
  # host has no follow-up work; it settles in `settle_turn/4`.
  @impl true
  def after_turn(host_state, _result, _opts), do: host_state

  defp context_of(loaded) do
    %{
      cwd: loaded.cwd,
      project: loaded.project,
      review: %{
        review_id: loaded.review_id,
        title: loaded.title,
        base_ref: loaded.base_ref,
        head_ref: loaded.head_ref
      }
    }
  end

  defp anchor_of(%State{context: context}), do: get_in(context, [:turn, :anchor])

  # Every viewer needs to know which line a question was asked about, not just
  # the one that asked it. The topic is derived here from the same conversation
  # key `Tackle.Web.AgentSession` subscribes with.
  defp broadcast(%{loaded: %{project: project, review_id: review_id}}, message) do
    topic = Tackle.Phoenix.PubSub.topic(AgentConversation.key(project.slug, review_id), nil)

    Phoenix.PubSub.broadcast(Tackle.Web.PubSub, topic, message)
  end

  defp broadcast(_host_state, _message), do: :ok

  defp persist(%{loaded: %{project: project, review_id: review_id}} = host_state, state) do
    path = AgentConversation.path(project.slug, review_id)

    case AgentConversation.save(path, state.messages, host_state.anchors) do
      :ok ->
        host_state

      {:error, reason} ->
        Logger.warning("Could not store the assistant transcript at #{path}: #{inspect(reason)}")
        host_state
    end
  end

  defp persist(host_state, _state), do: host_state
end

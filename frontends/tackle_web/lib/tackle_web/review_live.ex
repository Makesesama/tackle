defmodule Tackle.Web.ReviewLive do
  @moduledoc """
  Reviews one diff inside a project: the diff itself, the comments on it, which
  files a reviewer has been through, and the assistant you can ask about the
  code.

  The review is whatever its project's source says it is —
  `Tackle.Web.Project.Source` for the contract, `Tackle.Web.Projects.load_review/2`
  for the call. A GitHub pull request and a local `base..head` range arrive here
  as the same map: a diff, a title, two refs and a checkout. Nothing on this
  screen asks where the code came from.

  The diff is computed locally from a checkout rather than read from an API.
  GitHub reports comment positions as hunk offsets, which shift as soon as the
  pull request head moves, so comments here are anchored to `{path, side, line}`
  instead and survive a rebase.

  Review state is shared: it lives in `Tackle.Web.ReviewStore` under
  `{project slug, review id}`, and every viewer of this review is subscribed to
  its changes, so a comment left in one browser appears in another without a
  reload.

  ## Asking the assistant

  The assistant is a `Tackle.Phoenix.Runner` conversation per review, wired
  through `Tackle.Web.AgentSession`. A question is asked *from a place in the
  diff*: selecting a line — by clicking its number, dragging over several, or
  shift-clicking to extend — with the selection published to this process by
  `assets/js/app.js`.

  Answers are not rendered inside the diff. They are shown in the panel on the
  right, each thread naming the lines it is about and linking back to them. The
  diff stays a diff, and the conversation stays readable as a conversation.

  The anchor is part of the conversation, not a detail of the browser tab that
  asked it: `Tackle.Web.AgentStore` records it and announces it on the
  conversation topic, which is how other viewers place an answer they did not
  ask for.

  `Tackle.Phoenix.EventReducer` drives the streaming state: it keeps
  `:agent_state` and `:streaming_messages` up to date and filters reasoning and
  tool-input deltas out of the visible answer. This surface renders the threads
  `Tackle.Web.AgentThreads` derives from `agent_state`, because a message stream
  renders in one place and these threads are spread across the diff.
  """

  use Tackle.Web, :live_view

  import Tackle.Web.Components.Assistant, only: [thread: 1]
  import Tackle.Web.Components.Diff

  alias Phoenix.LiveView.AsyncResult
  alias Tackle.Lib.Event
  alias Tackle.Lib.State
  alias Tackle.Phoenix.EventReducer
  alias Tackle.Web.AgentActivity
  alias Tackle.Web.AgentMessageView
  alias Tackle.Web.AgentSession
  alias Tackle.Web.AgentThreads
  alias Tackle.Web.Anchor
  alias Tackle.Web.Projects
  alias Tackle.Web.Question
  alias Tackle.Web.Review
  alias Tackle.Web.ReviewStore

  @impl true
  def mount(%{"slug" => slug, "review_id" => review_id}, _session, socket) do
    case Projects.get(slug) do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/projects")}

      project ->
        if connected?(socket) do
          ReviewStore.subscribe(slug, review_id)
          AgentSession.subscribe(slug, review_id)
        end

        socket =
          socket
          |> assign(
            page_title: "#{project.name} · #{review_id}",
            project: project,
            slug: slug,
            review_id: review_id,
            review_state: ReviewStore.get(slug, review_id),
            pull: nil,
            comment_at: nil,
            comment_error: nil,
            ask_at: nil,
            agent_error: nil,
            activity: nil,
            processing: false,
            runner_pid: nil,
            anchors: %{},
            agent: nil,
            tackle_message_view: AgentMessageView,
            loaded: AsyncResult.loading()
          )
          |> start_async(:loaded, fn -> load(project, review_id) end)

        {:ok, socket}
    end
  end

  # `start_async/3` rather than `assign_async/3`: the completion has to set the
  # agent assigns the reducer needs, and only `start_async` runs the callback
  # where that can happen.
  @impl true
  def handle_async(:loaded, {:ok, {:ok, %{review: review, agent: snapshot}}}, socket) do
    socket =
      socket
      |> assign(
        loaded: AsyncResult.ok(socket.assigns.loaded, review),
        loaded_review: review,
        pull: Map.get(review, :pull),
        anchors: snapshot.anchors,
        agent_state: snapshot.agent_state,
        processing: snapshot.turn_active?,
        runner_pid: snapshot.runner_pid
      )
      |> EventReducer.init_stream(snapshot.agent_state)
      |> refresh_agent()

    {:noreply, socket}
  end

  def handle_async(:loaded, {:ok, {:error, reason}}, socket) do
    {:noreply, fail_load(socket, {:error, reason})}
  end

  def handle_async(:loaded, {:exit, reason}, socket) do
    {:noreply, fail_load(socket, {:exit, reason})}
  end

  @impl true
  def handle_info({:review_updated, _key}, socket) do
    {:noreply, refresh_review(socket)}
  end

  def handle_info({:agent_anchor, message_id, anchor}, socket) do
    anchors = Map.put(socket.assigns.anchors, message_id, anchor)

    {:noreply, socket |> assign(:anchors, anchors) |> refresh_agent()}
  end

  def handle_info({:agent_event, %Event{} = event}, socket) do
    socket =
      socket
      |> track_activity(event)
      |> EventReducer.handle_tackle_event(event)
      |> refresh_agent()

    {:noreply, socket}
  end

  def handle_info({:agent_turn_done, {status, %State{} = state}}, socket)
      when status in [:ok, :error, :cancelled] do
    socket =
      socket
      |> assign(processing: false, runner_pid: nil, activity: nil)
      |> EventReducer.clear_streaming_messages()
      |> EventReducer.sync_message_stream(state)
      |> put_agent_state(state)
      |> put_turn_error(status)

    {:noreply, socket}
  end

  def handle_info({:agent_turn_failed, reason}, socket) do
    {:noreply, fail_turn(socket, "The assistant stopped unexpectedly: #{inspect(reason)}")}
  end

  @impl true
  def handle_event("toggle_viewed", %{"path" => path}, socket) do
    %{slug: slug, review_id: review_id} = socket.assigns

    ReviewStore.toggle_viewed(slug, review_id, path)
    {:noreply, refresh_review(socket)}
  end

  @impl true
  def handle_event("comment_at", %{"path" => path, "side" => side, "line" => line}, socket) do
    case anchor(side, line) do
      {:ok, side, number} ->
        {:noreply, assign(socket, comment_at: {path, side, number}, comment_error: nil)}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_comment", _params, socket) do
    {:noreply, assign(socket, :comment_at, nil)}
  end

  @impl true
  def handle_event("add_comment", %{"comment" => comment}, socket) do
    %{slug: slug, review_id: review_id} = socket.assigns

    case ReviewStore.add_comment(slug, review_id, comment) do
      {:ok, _comment} ->
        {:noreply, socket |> assign(comment_at: nil, comment_error: nil) |> refresh_review()}

      {:error, reason} ->
        {:noreply, assign(socket, :comment_error, reason)}
    end
  end

  @impl true
  def handle_event("delete_comment", %{"id" => id}, socket) do
    %{slug: slug, review_id: review_id} = socket.assigns

    ReviewStore.delete_comment(slug, review_id, id)
    {:noreply, refresh_review(socket)}
  end

  @impl true
  def handle_event("select_lines", params, socket) do
    # One event serves the JavaScript selection and the `?` button: the button
    # sends the line it sits on as an already-collapsed range, the hook sends the
    # two ends of the drag. `extend` is what a shift-click means — keep the
    # selection that is there and grow it to this line.
    from = params["from"] || params["line"]
    to = params["to"] || params["line"]
    extend? = truthy(params["extend"]) or truthy(params["shiftKey"])

    with {:ok, _side, from} <- anchor(params["side"], from),
         {:ok, side, to} <- anchor(params["side"], to) do
      ask_at =
        if extend? do
          Anchor.extend(socket.assigns.ask_at, params["path"], side, to)
        else
          Anchor.new(params["path"], side, from, to)
        end

      {:noreply, socket |> assign(ask_at: ask_at, agent_error: nil) |> refresh_agent()}
    else
      :error -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("clear_selection", _params, socket) do
    {:noreply, socket |> assign(:ask_at, nil) |> refresh_agent()}
  end

  @impl true
  def handle_event("ask", %{"question" => %{"body" => body}}, socket) do
    # A question from the box above the diff is about the review as a whole; it
    # still gets an anchor, so its answer has somewhere to go and the transcript
    # can tell the two kinds apart.
    emit(socket, socket.assigns.ask_at || general_anchor(), body)
  end

  def handle_event("ask", _params, socket) do
    {:noreply, assign(socket, :agent_error, "Write a question first.")}
  end

  @impl true
  def handle_event("retry_turn", _params, socket) do
    %{loaded_review: review, agent_state: state, anchors: anchors} = socket.assigns

    case AgentSession.continue_turn(review, state, anchors: anchors) do
      {:ok, pid} ->
        {:noreply, start_turn_state(socket, pid)}

      {:error, reason} ->
        {:noreply, fail_turn(socket, turn_error(reason))}
    end
  end

  @impl true
  def handle_event("cancel_turn", _params, socket) do
    :ok = AgentSession.cancel_turn(socket.assigns.runner_pid)

    {:noreply, socket}
  end

  # Loading the review and reading its conversation is one unit of work: a review
  # is not worth showing until the diff it is about can be rendered, and the
  # assistant cannot be asked anything until the checkout it reads exists.
  defp load(project, review_id) do
    with {:ok, review} <- Projects.load_review(project, review_id),
         {:ok, agent} <- AgentSession.snapshot(review) do
      {:ok, %{review: review, agent: agent}}
    end
  end

  defp emit(%{assigns: %{processing: true}} = socket, _anchor, _body) do
    {:noreply, assign(socket, :agent_error, "Wait for the current question to finish.")}
  end

  defp emit(socket, anchor, body) when is_binary(body) do
    if String.trim(body) == "" do
      {:noreply, assign(socket, :agent_error, "Write a question first.")}
    else
      run_turn(socket, anchor, body)
    end
  end

  defp emit(socket, _anchor, _body) do
    {:noreply, assign(socket, :agent_error, "Write a question first.")}
  end

  defp run_turn(socket, anchor, body) do
    %{loaded_review: review, agent_state: state, anchors: anchors} = socket.assigns

    case AgentSession.run_turn(review, state, Question.prompt(anchor, body),
           anchor: anchor,
           anchors: anchors
         ) do
      {:ok, pid} ->
        {:noreply, start_turn_state(socket, pid)}

      {:error, reason} ->
        {:noreply, fail_turn(socket, turn_error(reason))}
    end
  end

  defp start_turn_state(socket, pid) do
    socket
    |> assign(ask_at: nil, processing: true, runner_pid: pid, agent_error: nil, activity: nil)
    |> refresh_agent()
  end

  # The location of the question is part of the question, so the transcript that
  # outlives the browser still says what was asked about. `Tackle.Web.Question`
  # owns both the prompt and the wording the panel shows back.
  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(_other), do: false

  # The store announces changes so other viewers stay in sync. Reading it back
  # here as well means the render answering this event is already up to date,
  # rather than a round trip behind its own broadcast.
  defp refresh_review(socket) do
    %{slug: slug, review_id: review_id} = socket.assigns

    assign(socket, :review_state, ReviewStore.get(slug, review_id))
  end

  defp put_agent_state(socket, %State{} = state) do
    socket |> assign(:agent_state, state) |> refresh_agent()
  end

  # `:agent` is what the diff and the panel read: the threads grouped by the
  # anchor comments use, plus the answer currently streaming, if any. It is
  # derived from the transcript, so it is recomputed whenever that changes.
  defp refresh_agent(socket) do
    case Map.get(socket.assigns, :agent_state) do
      %State{} = state ->
        threads = AgentThreads.all(state.messages, socket.assigns.anchors)
        grouped = AgentThreads.by_anchor(threads)
        ask_at = socket.assigns.ask_at

        streaming =
          AgentThreads.streaming(threads, Map.get(socket.assigns, :streaming_messages, %{}))

        assign(socket, :agent, %{
          list: threads,
          threads: grouped,
          thread_ids: thread_ids(grouped),
          streaming: streaming,
          streaming_entry: streaming |> Map.values() |> List.first(),
          ask_at: ask_at,
          ask_scope: ask_scope(ask_at)
        })

      _not_loaded ->
        assign(socket, :agent, nil)
    end
  end

  # The line a marker links to: the most recent thread asked about it. An anchor
  # can carry more than one thread, and the newest is the one a reader following
  # the marker wants.
  defp thread_ids(grouped) do
    Map.new(grouped, fn {key, threads} -> {key, List.last(threads).question.id} end)
  end

  # What the composer says the pending question is about. A question with no
  # selection is about the review as a whole, which needs no caption.
  defp ask_scope(nil), do: nil
  defp ask_scope(:general), do: nil
  defp ask_scope(anchor), do: "#{elem(anchor, 0)} #{Anchor.label(anchor)}"

  defp track_activity(socket, %Event{type: :tool_start, data: data}) do
    assign(socket, :activity, AgentActivity.label(data))
  end

  defp track_activity(socket, %Event{type: type}) when type in [:tool_end, :tool_error] do
    assign(socket, :activity, nil)
  end

  defp track_activity(socket, _event), do: socket

  defp put_turn_error(socket, :ok), do: assign(socket, :agent_error, nil)

  defp put_turn_error(socket, :error) do
    error = socket.assigns.agent_state |> Map.get(:error) |> Kernel.||("That turn failed.")

    assign(socket, :agent_error, to_string(error))
  end

  defp put_turn_error(socket, :cancelled), do: assign(socket, :agent_error, nil)

  defp fail_turn(socket, message) do
    socket
    |> assign(processing: false, runner_pid: nil, activity: nil, agent_error: message)
    |> EventReducer.clear_streaming_messages()
    |> refresh_agent()
  end

  defp fail_load(socket, reason) do
    assign(socket, :loaded, AsyncResult.failed(socket.assigns.loaded, reason))
  end

  defp turn_error({:checkout_missing, path}) do
    "The checkout at #{path} is gone. Reload to clone it again."
  end

  defp turn_error(:turn_in_progress), do: "The assistant is already answering a question."
  defp turn_error(reason), do: "Could not ask the assistant: #{inspect(reason)}"

  # The component builds anchors from the diff's own line numbers, which are
  # integers on the new or old side.
  defp anchor("new", line), do: anchor_of(:new, line)
  defp anchor("old", line), do: anchor_of(:old, line)
  defp anchor(_side, _line), do: :error

  defp anchor_of(side, line) do
    case Integer.parse(line) do
      {number, ""} when number > 0 -> {:ok, side, number}
      _invalid -> :error
    end
  end

  defp comments_for(review, path), do: Review.comments_by_line(review, path)

  # A provider adapter reports a missing login as its own error term, which is
  # accurate but not actionable on its own. The panel is where a reviewer meets
  # that error first, so it names the command that fixes it.
  defp credential_hint(message) when is_binary(message) do
    if String.contains?(String.downcase(message), [
         "credential",
         "not_authenticated",
         "unauthorized"
       ]) do
      "Sign in with `mix tackle auth`, or configure an API key for the provider."
    end
  end

  # The anchor of a question asked through the box above the diff.
  defp general_anchor, do: Anchor.general()

  defp asked?(%State{messages: messages}) do
    Enum.any?(messages, &(&1.role == :user))
  end

  defp asked?(_state), do: false

  defp reviewed_count(%{viewed: viewed}, files) do
    Enum.count(files, &MapSet.member?(viewed, &1.path))
  end
end

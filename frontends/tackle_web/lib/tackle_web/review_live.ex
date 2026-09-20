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
  through `Tackle.Web.AgentSession`. A question is asked *from a line* with the
  `?` beside it, and its answer is rendered under that line, next to the code it
  is about. Shift-clicking a second line extends the question to the range
  between them — `Tackle.Web.Anchor` describes the selection — and the answer
  then hangs under the range's last line. The anchor is part of the conversation,
  not a detail of the browser tab that asked it: `Tackle.Web.AgentStore` records
  it and announces it on the conversation topic, which is how other viewers place
  an answer they did not ask for.

  `Tackle.Phoenix.EventReducer` drives the streaming state: it keeps
  `:agent_state` and `:streaming_messages` up to date and filters reasoning and
  tool-input deltas out of the visible answer. This surface renders the anchored
  threads from `agent_state` rather than the reducer's message stream, because a
  message stream renders in one place and these answers render under many.
  """

  use Tackle.Web, :live_view

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
  def handle_event("ask_at", %{"path" => path, "side" => side, "line" => line} = params, socket) do
    case anchor(side, line) do
      {:ok, side, number} ->
        # A shift-click extends the selection to this line; a plain click starts a
        # new one. The modifier arrives as click metadata (see `assets/js/app.js`)
        # because LiveView does not send it by default.
        ask_at = ask_at(socket.assigns.ask_at, params["shiftKey"], path, side, number)

        {:noreply, socket |> assign(ask_at: ask_at, agent_error: nil) |> refresh_agent()}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_ask", _params, socket) do
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

    case AgentSession.run_turn(review, state, question(anchor, body),
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

  # The location of the question is part of the question. The assistant can read
  # the file itself, so a reference is enough — and unlike a hidden field it is
  # still readable in a transcript that has outlived the browser that asked.
  defp question(:general, body) do
    "About this review as a whole:\n\n#{String.trim(body)}"
  end

  # The selection is named with `Anchor.label/1`, the same wording the form shows,
  # so the assistant and the reviewer are told about the same region.
  defp question(anchor, body) when is_tuple(anchor) do
    path = elem(anchor, 0)
    side = elem(anchor, 1)

    "About #{path} #{Anchor.label(anchor)} (the #{side} side of the diff):\n\n" <>
      String.trim(body)
  end

  defp ask_at(ask_at, true, path, side, line), do: Anchor.extend(ask_at, path, side, line)
  defp ask_at(_ask_at, _shift, path, side, line), do: Anchor.new(path, side, line)

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

  # `:agent` is what the diff component reads: the threads grouped by the same
  # anchor comments use, plus the answer currently streaming, if any. It is
  # derived from the transcript, so it is recomputed whenever that changes.
  defp refresh_agent(socket) do
    case Map.get(socket.assigns, :agent_state) do
      %State{} = state ->
        threads = AgentThreads.all(state.messages, socket.assigns.anchors)

        assign(socket, :agent, %{
          threads: AgentThreads.by_anchor(threads),
          streaming:
            AgentThreads.streaming(threads, Map.get(socket.assigns, :streaming_messages, %{})),
          ask_at: socket.assigns.ask_at
        })

      _not_loaded ->
        assign(socket, :agent, nil)
    end
  end

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

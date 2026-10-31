defmodule Tackle.Phoenix.EventReducerTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias Tackle.Lib.Event
  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Phoenix.EventReducer

  defmodule MessageView do
    @behaviour Tackle.Phoenix.MessageView

    @impl true
    def group_messages(messages), do: Enum.map(messages, &{:visible, &1})

    @impl true
    def new_streaming_message, do: %{content: "", html: ""}

    @impl true
    def append_streaming_delta(entry, delta) do
      content = entry.content <> delta
      %{entry | content: content, html: "<p>#{content}</p>"}
    end
  end

  test "streams an assistant answer from start to settled message" do
    socket = mounted(State.new())

    socket =
      socket
      |> EventReducer.handle_tackle_event(Event.message_start(id: "answer"))
      |> EventReducer.handle_tackle_event(delta("answer", "Hel"))
      |> EventReducer.handle_tackle_event(delta("answer", "lo"))

    assert socket.assigns.streaming_messages == %{
             "answer" => %{content: "Hello", html: "<p>Hello</p>"}
           }

    assistant = Message.assistant(id: "answer", content: "Hello")
    socket = EventReducer.handle_tackle_event(socket, Event.message_end(assistant))

    assert socket.assigns.streaming_messages == %{}
    assert [%Message{id: "answer"}] = socket.assigns.agent_state.messages
    assert Map.has_key?(socket.assigns.message_stream_blocks, "agent-msg-block-answer")
  end

  test "keeps reasoning and tool input out of the visible message" do
    socket =
      mounted(State.new())
      |> EventReducer.handle_tackle_event(Event.message_start(id: "answer"))
      |> EventReducer.handle_tackle_event(
        Event.new(:message_delta, %{delta: "secret", field: :reasoning}, id: "answer")
      )
      |> EventReducer.handle_tackle_event(
        Event.new(:message_delta, %{delta: "{}", field: :tool_input}, id: "answer")
      )

    assert socket.assigns.streaming_messages == %{"answer" => %{content: "", html: ""}}
  end

  test "ignores message starts of other roles" do
    socket =
      EventReducer.handle_tackle_event(
        mounted(State.new()),
        Event.message_start(id: "user", role: :user)
      )

    assert socket.assigns.streaming_messages == %{}
  end

  test "does not add a settled message twice" do
    message = Message.assistant(id: "answer", content: "Hello")
    state = State.add_message(State.new(), message)

    socket = EventReducer.handle_tackle_event(mounted(state), Event.message_end(message))

    assert [^message] = socket.assigns.agent_state.messages
  end

  test "retry events clear only the provisional streaming message" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        streaming_messages: %{
          "pending-message" => %{content: "partial"},
          "other-message" => %{content: "settled elsewhere"}
        }
      }
    }

    event = Event.new(:retry_scheduled, %{attempt: 1}, id: "pending-message")
    socket = EventReducer.handle_tackle_event(socket, event)

    assert socket.assigns.streaming_messages == %{
             "other-message" => %{content: "settled elsewhere"}
           }
  end

  test "a finished turn clears every in-flight message" do
    socket =
      mounted(State.new())
      |> EventReducer.handle_tackle_event(Event.message_start(id: "answer"))
      |> EventReducer.handle_tackle_event(delta("answer", "partial"))
      |> EventReducer.handle_tackle_event(Event.turn_end("session", :cancelled))

    assert socket.assigns.streaming_messages == %{}
  end

  test "restoring in-flight text uses the host message view for later deltas" do
    socket =
      mounted(State.new())
      |> EventReducer.restore_streaming_messages(%{"answer" => %{content: "Hel"}})

    assert socket.assigns.streaming_messages["answer"] == %{content: "Hel", html: "<p>Hel</p>"}

    socket = EventReducer.handle_tackle_event(socket, delta("answer", "lo"))

    assert socket.assigns.streaming_messages["answer"] == %{
             content: "Hello",
             html: "<p>Hello</p>"
           }
  end

  test "requires a message view" do
    socket = %Socket{assigns: %{__changed__: %{}, streaming_messages: %{}}}

    assert_raise ArgumentError, ~r/tackle_message_view/, fn ->
      EventReducer.handle_tackle_event(socket, Event.message_start(id: "answer"))
    end
  end

  defp mounted(%State{} = state) do
    %Socket{
      assigns: %{
        __changed__: %{},
        agent_state: state,
        tackle_message_view: MessageView,
        tackle_stream_rows?: true
      },
      # What a mounted LiveView carries for streams.
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }
    |> EventReducer.init_stream(state)
  end

  defp delta(id, text), do: Event.new(:message_delta, %{delta: text}, id: id)
end

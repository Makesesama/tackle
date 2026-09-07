defmodule Tackle.Phoenix.MessageView do
  @moduledoc """
  Host seam for turning `Tackle.Message`s into renderable units.

  `Tackle.Phoenix.EventReducer` is otherwise pure — it only knows how to drive
  a LiveView stream of messages and a map of transient in-flight streaming
  bubbles. It defers *what a message looks like* entirely to a host module
  implementing this behaviour, so `Tackle.Phoenix` ships no opinion about
  markdown rendering, internal-step grouping, or bubble structure.

  A host implements the three callbacks (typically on an existing chat-component
  module) and passes the implementing module to the EventReducer.

  ## Example

      defmodule MyAppWeb.Components.AgentChat do
        @behaviour Tackle.Phoenix.MessageView

        @impl true
        def group_messages(messages), do: ...

        @impl true
        def new_streaming_message, do: %{content: "", html: ""}

        @impl true
        def append_streaming_delta(entry, delta), do: ...
      end
  """

  alias Tackle.Message

  @typedoc """
  A transient in-flight streaming message entry. Opaque to `Tackle.Phoenix`;
  the host decides its shape (e.g. accumulated content + parsed HTML).
  """
  @type streaming_entry :: term()

  @typedoc """
  A grouped message block. Convention used by the reducer's stream entries:
  `{:visible, message}` for a single user-facing message, or
  `{:internal, [message, ...]}` for a batch of consecutive internal steps. A
  host may also return a bare list of messages.
  """
  @type block ::
          {:visible, Message.t()}
          | {:internal, [Message.t()]}
          | [Message.t()]

  @doc """
  Groups a flat list of messages into renderable blocks for the stream.
  """
  @callback group_messages([Message.t()]) :: [block()]

  @doc """
  Returns a fresh, empty transient streaming-message entry.
  """
  @callback new_streaming_message() :: streaming_entry()

  @doc """
  Appends a text delta to a transient streaming-message entry.
  """
  @callback append_streaming_delta(streaming_entry(), String.t()) :: streaming_entry()
end

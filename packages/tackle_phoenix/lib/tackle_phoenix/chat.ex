defmodule Tackle.Phoenix.Chat do
  @moduledoc """
  `use`-able LiveView mixin that wires the generic agent-chat plumbing.

  > #### Scaffold {: .info}
  > This module currently documents the intended surface. The injected
  > callbacks are planned for a later release. Until then it is a placeholder
  > so the namespace compiles.

  When complete, `use Tackle.Phoenix.Chat` will inject:

    * mount → subscribe to the session topic via `Tackle.Phoenix.PubSub` and
      initialize the message stream via `Tackle.Phoenix.EventReducer`.
    * `handle_info({:agent_event, %Tackle.Lib.Event{}}, socket)` → reduce into the
      stream.
    * `handle_info({:agent_turn_done, {status, %Tackle.Lib.State{}}}, socket)` for
      `:ok` / `:error` / `:cancelled` → settle UI state and clear streaming
      messages.
    * `handle_info({:agent_turn_failed, reason}, socket)` → surface the error.

  The host LiveView keeps everything domain-specific: `render/1`, domain events
  (navigate / show-resource), tabs, model selector, and metadata editing.

  ## Required host wiring

    * Assign `:tackle_message_view` (a `Tackle.Phoenix.MessageView` impl) in
      mount before initializing the stream.
    * Provide the user/session identifiers used to build the PubSub topic.
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      # Injected mount/subscribe + settlement handle_info clauses land here in a
      # later extraction slice. Kept empty for now so hosts can `use` it without
      # behavioural change.
      @before_compile Tackle.Phoenix.Chat
    end
  end

  @doc false
  defmacro __before_compile__(_env), do: :ok
end

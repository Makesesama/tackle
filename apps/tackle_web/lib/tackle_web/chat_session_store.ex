defmodule Tackle.Web.ChatSessionStore do
  @moduledoc """
  Host side of `Tackle.Phoenix.Runner` for chat conversations.

  The Store is the seam the Runner expects the host to own: authorization,
  enrichment, persistence and settlement. This host has no accounts and no
  billing, so what is left is the part that is real:

    * `before_turn/2` fails closed when the conversation is gone or its
      directory no longer exists, rather than starting a turn whose every tool
      call would fail.
    * `enrich_state/3` re-pins the working directory from the stored
      conversation. The Runner treats the agent's context as opaque, so this is
      the only place that decides which directory the assistant may touch; a
      caller cannot move a running conversation by passing another one.
    * `persist_user_message/3` records the question as soon as it is asked, so a
      reload during a long turn still shows what was asked.
    * `settle_turn/4` writes the transcript back, including for failed and
      cancelled turns, so a half-finished exchange is not silently lost.
    * `current_session_id/1` returns `nil` deliberately. The Runner then
      broadcasts on one stable per-conversation topic instead of switching to a
      session topic mid-turn, which keeps every viewer in step without relying
      on the dual-topic fan-out.

  Everything is held by `Tackle.Web.ChatStore` in memory; see that module for
  what that means and where a durable store would take over.

  Host state is `%{conversation_id: id}`.
  """

  @behaviour Tackle.Phoenix.Store

  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Web.ChatStore

  @typedoc "Opaque Runner state: which conversation the turn belongs to."
  @type host_state :: %{conversation_id: String.t()}

  @impl true
  def before_turn(%{conversation_id: id}, _opts) do
    case ChatStore.get(id) do
      nil ->
        {:error, :conversation_gone}

      %{cwd: cwd} ->
        if is_binary(cwd) and File.dir?(cwd), do: :ok, else: {:error, {:workspace_missing, cwd}}
    end
  end

  @impl true
  def enrich_state(%{conversation_id: id}, %State{} = state, opts) do
    case ChatStore.get(id) do
      nil -> state
      conversation -> %{state | context: context(state, conversation, opts)}
    end
  end

  @impl true
  def persist_user_message(%{conversation_id: id}, _state, %Message{} = message) do
    ChatStore.append_message(id, message)
    host_state(id)
  end

  @impl true
  def settle_turn(%{conversation_id: id} = host_state, result, _usage, _opts) do
    case result do
      {_status, %State{} = state} -> ChatStore.put_messages(id, state.messages)
      _other -> :ok
    end

    host_state
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

  defp context(%State{context: context}, conversation, opts) do
    turn =
      context
      |> Map.get(:turn, %{})
      |> Map.put_new(:metadata, Keyword.get(opts, :turn_metadata, %{}))

    # `:persistence` has to exist as a map: the Runner records that it persisted
    # the user message by updating `context.persistence.persisted_ids`, and
    # `update_in/3` does not create intermediate keys.
    context
    |> Map.put_new(:persistence, %{})
    |> Map.merge(%{cwd: conversation.cwd, conversation_id: conversation.id, turn: turn})
  end

  defp host_state(id), do: %{conversation_id: id}
end

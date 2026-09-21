defmodule Tackle.Web.Components.Chat do
  @moduledoc """
  Rendering for the chat surface: the conversation list, message bubbles, and
  the collapsed record of the work behind an answer.

  The blocks this renders are produced by `Tackle.Web.ChatMessageView` and
  delivered by `Tackle.Phoenix.EventReducer`'s stream, so the three modules line
  up one-to-one: the view decides what a block is, the reducer streams it, and
  these components give it a shape.

  The shape is the design system's (`Tackle.Web.Components.UI`): the reader's
  questions are the filled pink bubbles, the assistant's answers are plain
  panels, and the work behind an answer is a disclosure. Long tool output and
  long reasoning are truncated rather than hidden — a reader who opens a step
  wants to see what the tool did, not to load an entire file into the page; the
  answer the model produced from it is already visible above.
  """

  use Tackle.Web, :html

  alias Tackle.Lib.Message

  @max_output_chars 4_000
  @max_thinking_chars 4_000
  @max_command_chars 120

  @doc "The list of one project's conversations, newest first, with the current one marked."
  attr(:conversations, :list, required: true)
  attr(:slug, :string, required: true)
  attr(:current_id, :string, default: nil)

  def chat_sidebar(assigns) do
    ~H"""
    <aside class="flex w-72 flex-none flex-col border-r border-base-300 bg-base-200">
      <div class="flex-none p-2">
        <.button navigate={~p"/projects/#{@slug}"} variant="ghost" class="w-full justify-start">
          <.icon name="hero-plus-mini" class="size-4" /> New chat
        </.button>
      </div>

      <nav class="min-h-0 flex-1 overflow-y-auto px-2 pb-2">
        <p :if={@conversations == []} class="px-2.5 py-4 text-xs leading-relaxed text-base-content/45">
          No conversations yet. They are kept in memory, so they last until this server stops.
        </p>

        <div :for={conversation <- @conversations} class="group relative mb-1">
          <.link
            navigate={~p"/projects/#{@slug}/chats/#{conversation.id}"}
            class={[
              "block rounded-lg border px-2.5 py-2 transition-colors",
              conversation.id == @current_id && "border-primary/20 bg-accent",
              conversation.id != @current_id && "border-transparent hover:bg-base-300/60"
            ]}
          >
            <span class={[
              "block truncate pr-5 text-xs",
              conversation.id == @current_id && "font-medium text-accent-content"
            ]}>
              {conversation.title}
            </span>
            <span class="mt-0.5 block truncate text-[0.6875rem] text-base-content/45">
              {conversation.message_count} messages · {Path.basename(conversation.cwd)}
            </span>
          </.link>

          <.icon_button
            size="xs"
            variant="danger"
            class="absolute right-1.5 top-1.5 opacity-0 transition-opacity group-hover:opacity-100 focus-visible:opacity-100"
            phx-click="delete"
            phx-value-id={conversation.id}
            title="Delete this conversation"
          >
            <.icon name="hero-trash-micro" class="size-3" />
          </.icon_button>
        </div>
      </nav>
    </aside>
    """
  end

  @doc "One grouped block of the transcript: a visible message or collapsed work."
  attr(:block, :any, required: true)

  def message_block(assigns) do
    ~H"""
    <%= case @block do %>
      <% {:visible, %Message{role: :user} = message} -> %>
        <.chat_message role={:user} message={message} />
      <% {:visible, %Message{} = message} -> %>
        <.chat_message role={:assistant} message={message} />
      <% {:internal, messages} -> %>
        <.internal_work messages={messages} />
    <% end %>
    """
  end

  @doc "One question or answer."
  attr(:role, :atom, required: true)
  attr(:message, :map, required: true)

  def chat_message(assigns) do
    ~H"""
    <div class={["chat-message", "chat-message--#{@role}"]}>
      <p class="chat-text">{@message.content}</p>
    </div>
    """
  end

  @doc "The tool calls, results, and reasoning that produced an answer."
  attr(:messages, :list, required: true)

  def internal_work(assigns) do
    ~H"""
    <details class="chat-work">
      <summary class="chat-work-summary">{work_summary(@messages)}</summary>
      <div class="chat-work-body">
        <.work_step :for={message <- @messages} message={message} />
      </div>
    </details>
    """
  end

  @doc "One internal message: a tool result, a tool call, or reasoning."
  attr(:message, :map, required: true)

  def work_step(%{message: %Message{role: :tool}} = assigns) do
    ~H"""
    <div class="chat-work-step">
      <p class="chat-work-tool">{@message.tool_name || "tool"}</p>
      <pre :if={output(@message)} class="chat-work-output">{output(@message)}</pre>
    </div>
    """
  end

  def work_step(assigns) do
    ~H"""
    <div class="chat-work-step">
      <p :if={thinking(@message)} class="chat-work-thinking">{thinking(@message)}</p>
      <p :for={call <- tool_calls(@message)} class="chat-work-call">{tool_call_label(call)}</p>
    </div>
    """
  end

  @doc "How many steps a collapsed block holds."
  def work_summary(messages) when is_list(messages) do
    steps = Enum.reduce(messages, 0, &count_steps/2)
    label = if steps == 1, do: "1 step", else: "#{steps} steps"

    if Enum.any?(messages, &thinking/1), do: label <> " · reasoning", else: label
  end

  defp count_steps(%Message{role: :tool}, count), do: count + 1

  defp count_steps(%Message{tool_calls: calls}, count) when is_list(calls),
    do: count + length(calls)

  defp count_steps(_message, count), do: count

  defp tool_calls(%Message{tool_calls: calls}) when is_list(calls), do: calls
  defp tool_calls(_message), do: []

  # A tool name and its most telling argument, so the collapsed block reads as a
  # list of actions rather than as JSON.
  defp tool_call_label(call) do
    case {call_name(call), call_arguments(call)} do
      {"bash", %{"command" => command}} when is_binary(command) ->
        "$ " <> truncate(command, @max_command_chars)

      {"read", %{"path" => path}} when is_binary(path) ->
        "read #{path}"

      {"write", %{"path" => path}} when is_binary(path) ->
        "write #{path}"

      {"edit", %{"path" => path}} when is_binary(path) ->
        "edit #{path}"

      {name, arguments} ->
        name <> arguments_suffix(arguments)
    end
  end

  defp call_name(call), do: Map.get(call, :name) || Map.get(call, "name") || "tool"

  defp call_arguments(call) do
    Map.get(call, :arguments) || Map.get(call, "arguments") || %{}
  end

  defp arguments_suffix(arguments) when is_map(arguments) and map_size(arguments) > 0 do
    " " <> truncate(JSON.encode!(arguments), @max_command_chars)
  rescue
    _error -> ""
  end

  defp arguments_suffix(_arguments), do: ""

  defp thinking(%Message{thinking: thinking}) when is_binary(thinking) do
    case String.trim(thinking) do
      "" -> nil
      trimmed -> truncate(trimmed, @max_thinking_chars)
    end
  end

  defp thinking(_message), do: nil

  defp output(%Message{content: content}) when is_binary(content) do
    case String.trim(content) do
      "" -> nil
      trimmed -> truncate(trimmed, @max_output_chars)
    end
  end

  defp output(_message), do: nil

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) <= max do
      text
    else
      String.slice(text, 0, max) <> "\n… (truncated)"
    end
  end
end

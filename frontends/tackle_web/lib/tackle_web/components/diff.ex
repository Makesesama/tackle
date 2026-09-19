defmodule Tackle.Web.Components.Diff do
  @moduledoc """
  Shared rendering for the unified diff views.

  Both the local diff viewer and the pull request view render the same file list
  and the same hunk body; the pull request view additionally passes review state,
  which turns each line into a place a comment can be anchored to.

  Passing `review: nil` renders the read-only form. That is the whole difference,
  so the two views cannot drift apart in how they show a diff.
  """

  use Phoenix.Component

  alias Tackle.Web.Diff

  @doc """
  The sidebar listing changed files, with a reviewed checkbox per file.

  The checkbox is only rendered when review state is passed.
  """
  attr(:files, :list, required: true)
  attr(:review, :map, default: nil)

  def file_nav(assigns) do
    ~H"""
    <nav class="flex flex-col py-1">
      <div :for={file <- @files} class="flex items-center gap-1.5 px-2 py-1 hover:bg-base-200">
        <input
          :if={@review}
          type="checkbox"
          class="checkbox checkbox-xs flex-none"
          checked={MapSet.member?(@review.viewed, file.path)}
          phx-click="toggle_viewed"
          phx-value-path={file.path}
          title="Mark this file as reviewed"
        />
        <a
          href={"#file-" <> file_id(file.path)}
          class="flex min-w-0 flex-1 items-center gap-2 text-xs"
        >
          <span class={["badge badge-xs flex-none", status_class(file.status)]}>
            {status_label(file.status)}
          </span>
          <span class="min-w-0 flex-1 truncate font-mono" title={file.path}>{file.path}</span>
          <span class="flex-none text-success">+{file.additions}</span>
          <span class="flex-none text-error">-{file.deletions}</span>
        </a>
      </div>
    </nav>
    """
  end

  @doc """
  One file's unified diff.

  `comments` maps `{side, line}` to the comments anchored there, and `comment_at`
  is the `{path, side, line}` whose form is currently open. `agent` carries the
  assistant's threads for the same anchors; `nil` renders the read-only form.
  """
  attr(:file, :map, required: true)
  attr(:review, :map, default: nil)
  attr(:comments, :map, default: nil)
  attr(:comment_at, :any, default: nil)
  attr(:agent, :map, default: nil)

  def file(assigns) do
    assigns = assign(assigns, :interactive, not is_nil(assigns.review))

    ~H"""
    <section id={"file-" <> file_id(@file.path)} class="border-b border-base-300">
      <header class="sticky top-0 z-10 flex items-center gap-2 border-b border-base-300 bg-base-200 px-3 py-2">
        <span class={["badge badge-sm flex-none", status_class(@file.status)]}>
          {status_label(@file.status)}
        </span>
        <span class="font-mono text-xs font-semibold">{@file.path}</span>
        <span :if={@file.status == :renamed} class="font-mono text-xs opacity-60">
          from {@file.old_path}
        </span>
        <span :if={@review} class="ml-3 flex items-center gap-1.5 text-xs">
          <input
            type="checkbox"
            class="checkbox checkbox-xs"
            checked={MapSet.member?(@review.viewed, @file.path)}
            phx-click="toggle_viewed"
            phx-value-path={@file.path}
          /> reviewed
        </span>
        <span class="ml-auto flex-none text-xs">
          <span class="text-success">+{@file.additions}</span>
          <span class="ml-1 text-error">-{@file.deletions}</span>
        </span>
      </header>

      <p :if={@file.hunks == []} class="px-3 py-2 font-mono text-xs opacity-60">
        No textual changes (binary, or name and mode only).
      </p>

      <div :for={hunk <- @file.hunks}>
        <div class="diff-hunk">{hunk.header}</div>
        <.line
          :for={line <- hunk.lines}
          line={line}
          path={@file.path}
          interactive={@interactive}
          comments={@comments}
          comment_at={@comment_at}
          agent={@agent}
        />
      </div>
    </section>
    """
  end

  @doc """
  A single rendered diff line, plus the comments and assistant threads anchored
  to it.
  """
  attr(:line, :map, required: true)
  attr(:path, :string, required: true)
  attr(:interactive, :boolean, default: false)
  attr(:comments, :map, default: nil)
  attr(:comment_at, :any, default: nil)
  attr(:agent, :map, default: nil)

  def line(assigns) do
    anchor = Diff.anchor(assigns.line)
    key = anchor && {assigns.path, elem(anchor, 0), elem(anchor, 1)}

    assigns =
      assigns
      |> assign(:anchor, anchor)
      |> assign(:key, key)
      |> assign(:line_id, line_id(anchor, assigns.path))
      |> assign(:thread, thread(assigns.comments, anchor))
      |> assign(:answers, agent_threads(assigns.agent, key))
      |> assign(:replying, agent_streaming(assigns.agent, key))
      |> assign(:asking, match?(%{ask_at: ^key}, assigns.agent))

    ~H"""
    <div class="diff-line-group" id={@line_id}>
      <div class={["diff-line group", "diff-line--#{@line.kind}"]}>
        <span class="diff-gutter">{@line.old}</span>
        <span class="diff-gutter">{@line.new}</span>
        <span class="diff-marker">{marker(@line.kind)}</span>
        <span :if={@line.kind == :note} class="diff-note">{@line.text}</span>
        <span :if={@line.kind != :note} class="diff-code">{Phoenix.HTML.raw(@line.html)}</span>
        <span class="diff-action">
          <button
            :if={@interactive and @anchor}
            type="button"
            class="diff-comment-action"
            phx-click="comment_at"
            phx-value-path={@path}
            phx-value-side={elem(@anchor, 0)}
            phx-value-line={elem(@anchor, 1)}
            title="Comment on this line"
          >
            +
          </button>
          <button
            :if={not is_nil(@agent) and not is_nil(@anchor)}
            type="button"
            class="diff-ask-action"
            phx-click="ask_at"
            phx-value-path={@path}
            phx-value-side={elem(@anchor, 0)}
            phx-value-line={elem(@anchor, 1)}
            title="Ask the assistant about this line"
          >
            ?
          </button>
        </span>
      </div>

      <div :for={comment <- @thread} class="diff-comment">
        <div class="flex items-baseline gap-2 text-[0.6875rem] opacity-60">
          <span class="font-semibold">{comment.author}</span>
          <span>{format_time(comment.inserted_at)}</span>
          <button
            type="button"
            class="ml-auto hover:underline"
            phx-click="delete_comment"
            phx-value-id={comment.id}
          >
            Delete
          </button>
        </div>
        <p class="whitespace-pre-wrap">{comment.body}</p>
      </div>

      <.thread :for={answer <- @answers} answer={answer} />

      <div :if={@replying} class="diff-answer diff-answer--streaming">
        <p class="diff-reply">{@replying.content}</p>
      </div>

      <form :if={@key && @comment_at == @key} phx-submit="add_comment" class="diff-comment-form">
        <input type="hidden" name="comment[path]" value={@path} />
        <input type="hidden" name="comment[side]" value={elem(@anchor, 0)} />
        <input type="hidden" name="comment[line]" value={elem(@anchor, 1)} />
        <textarea
          name="comment[body]"
          rows="3"
          autofocus
          class="textarea textarea-sm w-full font-mono text-xs"
          placeholder={"Comment on #{@path} line #{elem(@anchor, 1)}"}
        ></textarea>
        <div class="mt-1 flex gap-2">
          <button type="submit" class="btn btn-xs btn-primary">Comment</button>
          <button type="button" class="btn btn-xs btn-ghost" phx-click="cancel_comment">
            Cancel
          </button>
        </div>
      </form>

      <form :if={@asking} phx-submit="ask" class="diff-answer-form">
        <textarea
          name="question[body]"
          rows="3"
          autofocus
          class="textarea textarea-sm w-full font-mono text-xs"
          placeholder={"Ask about #{@path} line #{elem(@anchor, 1)}"}
        ></textarea>
        <div class="mt-1 flex gap-2">
          <button type="submit" class="btn btn-xs btn-secondary">Ask</button>
          <button type="button" class="btn btn-xs btn-ghost" phx-click="cancel_ask">
            Cancel
          </button>
        </div>
      </form>
    </div>
    """
  end

  @doc """
  Element id a file's section and its sidebar link agree on.
  """
  @spec file_id(Path.t()) :: String.t()
  def file_id(path), do: String.replace(path, ~r/[^A-Za-z0-9_-]/, "-")

  @doc """
  Element id for one line, so an answer can be linked to directly.

  A line is identified by the side and number it has in that file's diff, which
  is also its review anchor.
  """
  @spec line_id({:new | :old, pos_integer()} | nil, Path.t()) :: String.t() | nil
  def line_id({side, number}, path) do
    "line-#{file_id(path)}-L#{number}-#{side}"
  end

  def line_id(_anchor, _path), do: nil

  defp thread(comments, anchor) when is_map(comments) and not is_nil(anchor) do
    Map.get(comments, anchor, [])
  end

  defp thread(_comments, _anchor), do: []

  @doc """
  One question about the code and the answers it produced.

  Rendered under the line the question was asked about, and in the conversation
  area for questions that were about the pull request as a whole.
  """
  attr(:answer, :map, required: true)

  def thread(assigns) do
    ~H"""
    <div class="diff-answer">
      <p class="diff-question">{@answer.question.content}</p>
      <p :for={reply <- @answer.replies} class="diff-reply">{reply.content}</p>
      <p :if={@answer.steps > 0} class="diff-steps">
        {@answer.steps} step(s) without an answer
      </p>
    </div>
    """
  end

  @doc """
  The assistant's threads for one anchor, or `[]` when there are none.

  Threads are keyed like review comments (`{path, side, line}`), so this is the
  same key the caller already builds to compare against `comment_at`.
  """
  @spec agent_threads(map() | nil, term()) :: [map()]
  def agent_threads(%{threads: threads}, anchor)
      when is_map(threads) and not is_nil(anchor) do
    Map.get(threads, anchor, [])
  end

  def agent_threads(_agent, _anchor), do: []

  @doc """
  The answer currently streaming for one anchor, or `nil`.

  Only one turn runs per conversation, so at most one anchor has a streaming
  answer at a time.
  """
  @spec agent_streaming(map() | nil, term()) :: map() | nil
  def agent_streaming(%{streaming: streaming}, anchor)
      when is_map(streaming) and not is_nil(anchor) do
    Map.get(streaming, anchor)
  end

  def agent_streaming(_agent, _anchor), do: nil

  defp marker(:add), do: "+"
  defp marker(:remove), do: "-"
  defp marker(:context), do: ""
  defp marker(:note), do: ""

  defp status_label(:added), do: "added"
  defp status_label(:deleted), do: "deleted"
  defp status_label(:renamed), do: "renamed"
  defp status_label(:modified), do: "modified"

  defp status_class(:added), do: "badge-success"
  defp status_class(:deleted), do: "badge-error"
  defp status_class(:renamed), do: "badge-warning"
  defp status_class(:modified), do: "badge-neutral"

  defp format_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")
end

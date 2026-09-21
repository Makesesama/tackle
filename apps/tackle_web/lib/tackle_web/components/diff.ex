defmodule Tackle.Web.Components.Diff do
  @moduledoc """
  Shared rendering for the unified diff views.

  Both the local diff viewer and the pull request view render the same file list
  and the same hunk body; the pull request view additionally passes review state,
  which turns each line into a place a comment can be anchored to.

  Passing `review: nil` renders the read-only form. That is the whole difference,
  so the two views cannot drift apart in how they show a diff.

  The colours come from `Tackle.Web.Components.UI`: an added line is washed with
  the interface's one accent and a removed line is grey, so a diff reads without
  a second colour.
  """

  use Tackle.Web, :html

  alias Tackle.Web.Anchor
  alias Tackle.Web.Diff

  @doc """
  The sidebar listing changed files, with a reviewed checkbox per file.

  The checkbox is only rendered when review state is passed.
  """
  attr(:files, :list, required: true)
  attr(:review, :map, default: nil)

  def file_nav(assigns) do
    ~H"""
    <nav class="flex flex-col gap-0.5 p-1.5">
      <div
        :for={file <- @files}
        class="flex items-center gap-2 rounded-lg px-2 py-1.5 hover:bg-base-200"
      >
        <.input
          :if={@review}
          type="checkbox"
          checked={MapSet.member?(@review.viewed, file.path)}
          phx-click="toggle_viewed"
          phx-value-path={file.path}
          title="Mark this file as reviewed"
        />
        <a
          href={"#file-" <> file_id(file.path)}
          class="flex min-w-0 flex-1 items-center gap-2 text-xs"
        >
          <.badge tone={status_tone(file.status)}>{status_label(file.status)}</.badge>
          <span class="min-w-0 flex-1 truncate font-mono" title={file.path}>{file.path}</span>
          <.diff_stats additions={file.additions} deletions={file.deletions} />
        </a>
      </div>
    </nav>
    """
  end

  @doc """
  One file's unified diff.

  `comments` maps `{side, line}` to the comments anchored there, and `comment_at`
  is the `{path, side, line}` whose form is currently open.

  `agent` carries the assistant's threads grouped by the same anchors. It is what
  makes a line selectable for a question, and what puts a marker back on a line
  that has already been asked about. `nil` renders the read-only form.
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
      <header class="sticky top-0 z-10 flex items-center gap-2 border-b border-base-300 bg-base-100/95 px-3 py-2 backdrop-blur">
        <.badge tone={status_tone(@file.status)} size="sm">{status_label(@file.status)}</.badge>
        <span class="truncate font-mono text-xs font-medium">{@file.path}</span>
        <span :if={@file.status == :renamed} class="truncate font-mono text-xs text-base-content/45">
          from {@file.old_path}
        </span>
        <label
          :if={@review}
          class="ml-2 flex flex-none items-center gap-1.5 text-xs text-base-content/60"
        >
          <.input
            type="checkbox"
            checked={MapSet.member?(@review.viewed, @file.path)}
            phx-click="toggle_viewed"
            phx-value-path={@file.path}
          /> reviewed
        </label>
        <.diff_stats
          additions={@file.additions}
          deletions={@file.deletions}
          class="ml-auto flex-none"
        />
      </header>

      <p :if={@file.hunks == []} class="px-3 py-2 font-mono text-xs text-base-content/45">
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
  A single rendered diff line, the comments anchored to it, and the marker that
  says the assistant has been asked about it.

  Selecting a line for a question is the reviewer's gesture, not the browser's.
  The line carries the anchor it stands for in `data-` attributes, and
  `assets/js/app.js` turns a click, a drag or a shift-click on the line numbers
  into one selection; `?` does the same thing without JavaScript. The lines the
  selection covers are marked, so the region being asked about is visible before
  the question is written.

  A question's answer is not rendered here: threads live in
  `Tackle.Web.Components.Assistant`, beside the code rather than inside it. A line
  that has been asked about only carries a count, which links to the thread.
  """
  attr(:line, :map, required: true)
  attr(:path, :string, required: true)
  attr(:interactive, :boolean, default: false)
  attr(:comments, :map, default: nil)
  attr(:comment_at, :any, default: nil)
  attr(:agent, :map, default: nil)

  def line(assigns) do
    line_anchor = Diff.anchor(assigns.line)
    {side, number} = split(line_anchor)
    key = line_key(assigns.path, line_anchor)
    ask_at = assigns.agent && Map.get(assigns.agent, :ask_at)

    assigns =
      assigns
      |> assign(:anchor, line_anchor)
      |> assign(:side, side)
      |> assign(:number, number)
      |> assign(:key, key)
      |> assign(:line_id, line_id(line_anchor, assigns.path))
      |> assign(:thread, thread(assigns.comments, line_anchor))
      |> assign(:answer_count, answer_count(assigns.agent, key))
      |> assign(:thread_id, thread_id(assigns.agent, key))
      |> assign(:selectable, not is_nil(assigns.agent) and not is_nil(line_anchor))
      |> assign(:selected, Anchor.contains?(ask_at, assigns.path, side, number))

    ~H"""
    <div class="diff-line-group" id={@line_id}>
      <div
        class={[
          "diff-line group",
          "diff-line--#{@line.kind}",
          @selected && "diff-line--selected"
        ]}
        data-path={@selectable && @path}
        data-side={@selectable && @side}
        data-line={@selectable && @number}
      >
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
            phx-value-side={@side}
            phx-value-line={@number}
            title="Comment on this line"
            aria-label={"Comment on #{@path} line #{@number}"}
          >
            +
          </button>
          <button
            :if={@selectable}
            type="button"
            class="diff-ask-action"
            phx-click="select_lines"
            phx-value-path={@path}
            phx-value-side={@side}
            phx-value-from={@number}
            phx-value-to={@number}
            title="Ask the assistant about this line; shift-click another line to ask about a range"
            aria-label={"Ask the assistant about #{@path} line #{@number}"}
          >
            ?
          </button>
          <a
            :if={@answer_count > 0 and @thread_id}
            class="diff-thread-marker"
            href={"#" <> @thread_id}
            title={"#{@answer_count} question(s) asked about this line"}
          >
            {@answer_count}
          </a>
        </span>
      </div>

      <div :for={comment <- @thread} class="diff-comment">
        <div class="flex items-center gap-2 text-[0.6875rem] text-base-content/45">
          <span class="font-semibold text-base-content/70">{comment.author}</span>
          <span>{format_time(comment.inserted_at)}</span>
          <.button
            size="xs"
            variant="danger"
            class="ml-auto"
            phx-click="delete_comment"
            phx-value-id={comment.id}
          >
            Delete
          </.button>
        </div>
        <p class="mt-1 whitespace-pre-wrap">{comment.body}</p>
      </div>

      <form :if={@key && @comment_at == @key} phx-submit="add_comment" class="diff-comment-form">
        <input type="hidden" name="comment[path]" value={@path} />
        <input type="hidden" name="comment[side]" value={@side} />
        <input type="hidden" name="comment[line]" value={@number} />
        <.input
          type="textarea"
          name="comment[body]"
          rows="3"
          autofocus
          class="font-mono"
          placeholder={"Comment on #{@path} line #{@number}"}
        />
        <div class="mt-2 flex gap-2">
          <.button type="submit" size="xs">Comment</.button>
          <.button type="button" size="xs" variant="quiet" phx-click="cancel_comment">
            Cancel
          </.button>
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
  Element id for one line, so a thread can be linked back to the code it is about.

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

  # How many questions have been asked about this line. The threads themselves are
  # in the assistant panel; a diff line only has to say that there is something
  # to read.
  defp answer_count(%{threads: threads}, key) when is_map(threads) and not is_nil(key) do
    threads |> Map.get(key, []) |> length()
  end

  defp answer_count(_agent, _key), do: 0

  # The most recent thread for this line, so the marker links to it. Older threads
  # for the same line are still in the panel, just not the link's target.
  defp thread_id(%{thread_ids: ids}, key) when is_map(ids) and not is_nil(key) do
    case Map.get(ids, key) do
      nil -> nil
      id -> "thread-" <> id
    end
  end

  defp thread_id(_agent, _key), do: nil

  defp marker(:add), do: "+"
  defp marker(:remove), do: "-"
  defp marker(:context), do: ""
  defp marker(:note), do: ""

  # A diff line that carries no anchor (the no-newline marker) has no side, no
  # number and no key, so it can hold neither comments nor questions.
  defp split({side, number}), do: {side, number}
  defp split(_anchor), do: {nil, nil}

  defp line_key(path, {side, number}), do: {path, side, number}
  defp line_key(_path, _anchor), do: nil

  defp status_label(:added), do: "added"
  defp status_label(:deleted), do: "deleted"
  defp status_label(:renamed), do: "renamed"
  defp status_label(:modified), do: "modified"

  defp status_tone(:added), do: "added"
  defp status_tone(:deleted), do: "removed"
  defp status_tone(:renamed), do: "renamed"
  defp status_tone(:modified), do: "neutral"

  defp format_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")
end

defmodule Tackle.Web.Components.Assistant do
  @moduledoc """
  The assistant's half of a review: the conversation beside the diff.

  Answers are not rendered inside the diff. A thread hangs off the line it was
  asked about, but it is shown in the panel on the right — the diff stays a diff
  and the conversation stays readable as a conversation. The two halves point at
  each other: a thread names its anchor and links to the line, and a line that has
  been asked about carries a marker back here.

  A question's prompt carries its location, because the assistant has to be told
  what it is looking at. The thread shows only the wording that was typed, since
  the location is already named above it; `Tackle.Web.Question` owns both forms.
  """

  use Tackle.Web, :html

  alias Tackle.Web.Anchor
  alias Tackle.Web.Components.Diff
  alias Tackle.Web.Question

  @doc """
  One question and the answers it produced, under a note of where it was asked.

  The anchor is a link to the line it names, so reading a thread and reading the
  code it is about are one click apart.
  """
  attr(:thread, :map, required: true)

  def thread(assigns) do
    ~H"""
    <article id={"thread-" <> @thread.question.id} class="assistant-thread">
      <a :if={@thread.anchor == :general} href="#diff" class="assistant-anchor">
        this review
      </a>
      <a :if={@thread.anchor != :general} href={"#" <> line_id(@thread)} class="assistant-anchor">
        {anchor_path(@thread.anchor)}
        <span class="opacity-40">·</span>
        {Anchor.label(@thread.anchor)}
      </a>
      <p class="assistant-question">{Question.body(@thread.question.content)}</p>
      <p :for={reply <- @thread.replies} class="assistant-reply">{reply.content}</p>
      <p :if={@thread.steps > 0} class="assistant-steps">
        {@thread.steps} step(s) without an answer
      </p>
    </article>
    """
  end

  defp line_id(%{anchor: anchor}) do
    {path, side, line} = Anchor.key(anchor)
    Diff.line_id({side, line}, path)
  end

  defp anchor_path({path, _side, _line}), do: path
  defp anchor_path({path, _side, _first, _last}), do: path
end

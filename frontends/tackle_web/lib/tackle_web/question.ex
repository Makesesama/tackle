defmodule Tackle.Web.Question do
  @moduledoc """
  The wording of a question, in the two forms it exists in.

  A question is always asked *about somewhere* — a line, a range of lines, or the
  review as a whole — and the assistant has to be told where. The prompt carries
  that location, because the transcript is what the model reads and the anchor
  itself is host state it never sees.

  The reader, though, already has the location named beside the thread, so
  repeating it inside the question would say the same thing twice. `body/1`
  recovers the wording that was typed from the prompt that was sent, which is what
  the panel shows.

  Both halves live here so the prompt and its inverse cannot drift apart.
  """

  alias Tackle.Web.Anchor

  @separator "\n\n"

  @doc """
  The prompt sent to the assistant: where the question is about, then the
  question itself.

  `nil` is accepted for the no-anchor case so a caller never has to guard before
  asking.
  """
  @spec prompt(Anchor.at() | nil, String.t()) :: String.t()
  def prompt(nil, body), do: String.trim(body)

  def prompt(:general, body) do
    "About this review as a whole:" <> @separator <> String.trim(body)
  end

  def prompt(anchor, body) when is_tuple(anchor) do
    scope =
      "About #{elem(anchor, 0)} #{Anchor.label(anchor)} (the #{elem(anchor, 1)} side of the diff):"

    scope <> @separator <> String.trim(body)
  end

  @doc """
  The wording that was typed, recovered from the prompt that carried it.

  Only the first blank line separates the location from the question, so a
  question that contains blank lines of its own comes back whole.
  """
  @spec body(String.t()) :: String.t()
  def body(prompt) when is_binary(prompt) do
    case String.split(prompt, @separator, parts: 2) do
      [_scope, body] -> body
      [body] -> body
    end
  end
end

defmodule Tackle.CLI.TUI.Pastes do
  @moduledoc """
  Keeps large pasted text and image instructions out of the composer while
  retaining their contents for submission.

  A collapsed paste is a label the composer inserts in place of the content:
  `[Pasted Content N chars]` for text and `[Image #N]` for an image
  instruction. The label carries the count that tells pastes apart, so the
  composer and the transcript preview stay readable, while the full content is
  retained per label in the session's TUI state.

  `resolve/2` turns a draft into the prompt to send. A label-shaped span with
  no retained content — typed by hand, partly deleted, or left over from another
  session — is reported rather than expanded, so the agent never receives label
  text in place of the paste it stands for. A label whose count and brackets are
  gone is no longer recognisable as one, and is sent as ordinary text.
  """

  alias Tackle.CLI.TUI.State
  alias Tackle.CLI.Widgets.Input

  @long_text_chars 1_000

  # Codex's MAX_USER_INPUT_TEXT_CHARS. A collapsed paste costs the composer one
  # label but can expand far past what a request can carry, so the draft is
  # measured after expansion.
  @max_prompt_chars 1_048_576

  # A label this module inserts. Expansion only rewrites a complete label, so
  # edited prose is never replaced by paste content. Further pastes of one size
  # carry their number after the label.
  @label ~r/\[Pasted Content \d+ chars\](?: #\d+)?|\[Image #\d+\]/

  # A text label, complete or with something after its count cut short: the
  # trailing word, a bracket, or a digit of the `#N` suffix further pastes of one
  # size carry. The count is required in both forms, so prose that merely
  # mentions pasting stays literal.
  @text_label_candidate ~r/\[Pasted Content \d+[^\n\]]{0,10}\]?(?: #\d*)?|Pasted Content \d+[^\n\]]{0,10}\]/

  # Likewise for an image label, which carries no suffix.
  @image_label_candidate ~r/\[Image #\d*[^\n\]]{0,10}\]?|Image #\d+[^\n\]]{0,10}\]/

  # Anything in a draft that could stand for a paste: `@label`, or what is left
  # of one after an edit.
  @label_candidate ~r/#{Regex.source(@text_label_candidate)}|#{Regex.source(@image_label_candidate)}/

  @doc "Whether a text paste is large enough to collapse in the composer."
  @spec long_text?(String.t()) :: boolean()
  def long_text?(text), do: String.length(text) >= @long_text_chars

  @doc "The longest prompt `resolve/2` accepts, in characters."
  @spec max_prompt_chars() :: pos_integer()
  def max_prompt_chars, do: @max_prompt_chars

  @doc "Inserts a label for a paste and retains its full value for submission."
  @spec insert(State.t(), :image | :text, String.t()) :: State.t()
  def insert(%State{} = state, kind, content) when kind in [:image, :text] do
    draft = Input.get_value(state.input)
    label = next_label(draft, state.paste_replacements, kind, content)
    prefix = if draft == "" or String.ends_with?(draft, [" ", "\n"]), do: "", else: " "
    :ok = Input.insert_str(state.input, prefix <> label)

    %{state | paste_replacements: Map.put(state.paste_replacements, label, content)}
  end

  # Expands retained labels. Only `resolve/2` may use the result: a label it
  # does not know is left in place here.
  @spec expand(String.t(), State.t()) :: String.t()
  defp expand(text, %State{} = state) when is_binary(text) do
    replacements = replacements(state)
    Regex.replace(@label, text, fn label -> Map.get(replacements, label, label) end)
  end

  @doc """
  Resolves a draft into the prompt to send.

  Returns `{:error, {:unresolved_pastes, labels}}` when the draft holds a
  label-shaped span with no retained content, and `{:error, {:prompt_too_long,
  chars}}` when the expanded prompt is longer than `max_prompt_chars/0`.
  """
  @spec resolve(String.t(), State.t()) ::
          {:ok, String.t()}
          | {:error, {:unresolved_pastes, [String.t()]} | {:prompt_too_long, pos_integer()}}
  def resolve(text, %State{} = state) when is_binary(text) do
    case unresolved(text, replacements(state)) do
      [] ->
        prompt = text |> expand(state) |> String.trim()
        chars = String.length(prompt)

        if chars > @max_prompt_chars,
          do: {:error, {:prompt_too_long, chars}},
          else: {:ok, prompt}

      labels ->
        {:error, {:unresolved_pastes, labels}}
    end
  end

  @doc "Collapses retained paste contents in transcript previews."
  @spec collapse(String.t(), State.t()) :: String.t()
  def collapse(text, state) when is_binary(text) do
    state
    |> replacements()
    |> Enum.sort_by(fn {_label, value} -> -byte_size(value) end)
    |> Enum.reduce(text, fn {label, value}, acc ->
      if value == "" do
        acc
      else
        acc
        |> String.replace(value, label)
        |> String.replace(String.trim(value), label)
      end
    end)
  end

  defp next_label(draft, replacements, :image, _content) do
    used = used_labels(draft, replacements)
    number = Enum.find(1..(MapSet.size(used) + 1), &(not MapSet.member?(used, image_label(&1))))
    image_label(number)
  end

  defp next_label(draft, replacements, :text, content) do
    used = used_labels(draft, replacements)
    base = text_label(String.length(content))

    if MapSet.member?(used, base) do
      base <> " #" <> Integer.to_string(highest_suffix(used, base) + 1)
    else
      base
    end
  end

  defp image_label(number), do: "[Image ##{number}]"
  defp text_label(chars), do: "[Pasted Content #{chars} chars]"

  # Labels already spoken for, by the draft or by this session's retained
  # contents, so a label is never reused for different content.
  defp used_labels(draft, replacements) do
    draft
    |> then(&Regex.scan(@label, &1, capture: :first))
    |> List.flatten()
    |> MapSet.new()
    |> MapSet.union(MapSet.new(Map.keys(replacements)))
  end

  # Pastes of one size share a base label and are told apart by a suffix, the
  # way Codex numbers them. The base label itself counts as the first.
  defp highest_suffix(labels, base) do
    prefix = base <> " #"

    Enum.reduce(labels, 1, fn label, highest ->
      with(
        true <- String.starts_with?(label, prefix),
        {suffix, ""} <- Integer.parse(String.replace_prefix(label, prefix, ""))
      ) do
        max(highest, suffix)
      else
        _other -> highest
      end
    end)
  end

  # Label-shaped spans whose content the session no longer retains: a label
  # typed by hand, one an edit left incomplete, or one from another session.
  # Spans are compared whole, so a retained label is never a prefix of a
  # fragment that escapes the check.
  defp unresolved(text, replacements) do
    text
    |> then(&Regex.scan(@label_candidate, &1, capture: :first))
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.reject(&Map.has_key?(replacements, &1))
  end

  defp replacements(state) when is_map(state), do: Map.get(state, :paste_replacements, %{})
end

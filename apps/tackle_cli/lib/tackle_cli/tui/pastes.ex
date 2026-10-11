defmodule Tackle.CLI.TUI.Pastes do
  @moduledoc """
  Keeps large pasted text and image instructions out of the composer while
  retaining their contents for submission and for transcript previews.

  A collapsed paste is a label the composer holds as an atomic element:
  `[Pasted Content N chars]` for text and `[Image #N]` for an image
  instruction. Each label stands for one payload the session retains, keyed by
  the id the editor stores next to the label's byte range.

  Identity is structural, not textual. `resolve/2` walks the elements the
  editor reports and splices in the payload each id names, so label-shaped text
  the user typed — or half-deleted by an edit — is ordinary prose the model
  receives as written. A label an edit rewrote is no longer an element: it can
  neither expand nor be mistaken for a paste.

  A draft's text and elements travel together as a `Draft` (`draft/1`,
  `restore/2`, `merge/2`), which is what lets a failed submission, recalled
  prompt history, and a withdrawn queued message put back exactly what the user
  had — label and payload — instead of flattening it into text. Labels are
  numbered across the session, so a label in a transcript always names one
  payload.

  `collapse/2` is the transcript's view of the same payloads: it rewrites each
  retained content back to the label that stands for it, and an image label
  also names the file it points at when the paste gave a path.
  """

  alias Tackle.CLI.TUI.State
  alias Tackle.CLI.Widgets.Input

  @long_text_chars 1_000

  # Codex's MAX_USER_INPUT_TEXT_CHARS. A collapsed paste costs the composer one
  # label but can expand far past what a request can carry, so the draft is
  # measured after expansion.
  @max_prompt_chars 1_048_576

  defmodule Draft do
    @moduledoc """
    A composer draft: its text plus the paste labels it holds as elements.

    `spans` are `{payload_id, byte_start, byte_stop}` into `text`, in order.
    They are what `Tackle.CLI.Widgets.Input` re-attaches on `restore/2`.
    """

    @typedoc "A retained payload id and the byte range its label occupies."
    @type span :: {id :: non_neg_integer(), start :: non_neg_integer(), stop :: non_neg_integer()}

    @type t :: %__MODULE__{text: String.t(), spans: [span()]}

    defstruct text: "", spans: []

    @doc "A draft from its text and element spans."
    @spec new(String.t(), [span()]) :: t()
    def new(text \\ "", spans \\ []), do: %__MODULE__{text: text, spans: spans}
  end

  defmodule Paste do
    @moduledoc """
    One retained paste: the label that stands for it in the composer, the text
    submission splices in its place, and the label a transcript preview shows.
    """

    @type kind :: :text | :image

    @type t :: %__MODULE__{
            id: non_neg_integer(),
            kind: kind(),
            label: String.t(),
            content: String.t(),
            display: String.t()
          }

    defstruct [:id, :kind, :label, :content, :display]
  end

  @doc "Whether a text paste is large enough to collapse in the composer."
  @spec long_text?(String.t()) :: boolean()
  def long_text?(text), do: String.length(text) >= @long_text_chars

  @doc "The longest prompt `resolve/2` accepts, in characters."
  @spec max_prompt_chars() :: pos_integer()
  def max_prompt_chars, do: @max_prompt_chars

  @doc """
  Inserts a label for a paste and retains its full value for submission.

  `:source` names the file an image instruction points at — a path the user
  pasted, not a temporary copy the shell staged — so transcript previews can
  name it next to the label.
  """
  @spec insert(State.t(), :image | :text, String.t(), keyword()) :: State.t()
  def insert(%State{} = state, kind, content, opts \\ []) when kind in [:image, :text] do
    id = state.next_paste_id
    label = next_label(state, kind, content)
    prefix = label_prefix(Input.get_value(state.input))
    :ok = Input.insert_element(state.input, prefix, label, id)

    paste = %Paste{
      id: id,
      kind: kind,
      label: label,
      content: content,
      display: display(kind, label, Keyword.get(opts, :source))
    }

    %{state | pastes: Map.put(state.pastes, id, paste), next_paste_id: id + 1}
  end

  @doc "The live draft: the composer's text together with its paste elements."
  @spec draft(State.t()) :: Draft.t()
  def draft(%State{input: input}) do
    %Draft{text: Input.get_value(input), spans: Input.elements(input)}
  end

  @doc """
  Loads a draft back into the composer, labels and all.

  The payloads it names are the session's, so a draft restored after a failed
  submission, a recall, or a withdrawal is the one the user wrote.

  A span the editor refuses — only a draft whose text and spans disagree, which
  is a bug rather than a user action — cannot stand for its payload any more, so
  the label is dropped from the restored text along with it. A label must never
  reach the model in place of the paste it names, and the notice says so.
  """
  @spec restore(State.t(), Draft.t()) :: State.t()
  def restore(%State{input: input} = state, %Draft{text: text, spans: spans}) do
    case Input.restore(input, text, spans) do
      {:ok, ^spans} ->
        state

      {:ok, accepted} ->
        {text, spans} = without_rejected(text, spans, accepted)
        {:ok, _attached} = Input.restore(input, text, spans)
        %{state | notice: "Paste labels could not be restored · draft kept"}
    end
  end

  # Drops the spans the editor refused, and the label text that stood for them,
  # keeping every other span addressable at its new offset. A refused span may
  # describe more text than the draft holds, so its range is read against the
  # text it actually names.
  defp without_rejected(text, spans, accepted) do
    accepted = MapSet.new(accepted)
    size = byte_size(text)

    {parts, kept, cursor, _dropped} =
      Enum.reduce(spans, {[], [], 0, 0}, fn {id, start, stop} = span,
                                            {parts, kept, cursor, dropped} ->
        start = clamp(start, cursor, size)
        stop = clamp(stop, start, size)
        parts = [parts, binary_part(text, cursor, start - cursor)]

        if MapSet.member?(accepted, span) do
          {parts, [{id, start - dropped, stop - dropped} | kept], stop, dropped}
        else
          {parts, kept, stop, dropped + stop - start}
        end
      end)

    body = IO.iodata_to_binary([parts, binary_part(text, cursor, size - cursor)])
    {body, Enum.reverse(kept)}
  end

  defp clamp(value, low, high), do: value |> max(low) |> min(high)

  @doc """
  Trims a draft, keeping its labels addressable.

  Returns `nil` for a draft that is only whitespace. Trimming only ever removes
  whitespace outside the labels, so no span is cut apart.
  """
  @spec normalize(Draft.t()) :: Draft.t() | nil
  def normalize(%Draft{text: text} = draft) do
    case String.trim(text) do
      "" ->
        nil

      trimmed ->
        shift = byte_size(String.trim_leading(text)) - byte_size(text)
        %Draft{text: trimmed, spans: shift_spans(draft.spans, shift, byte_size(trimmed))}
    end
  end

  @doc """
  Puts `older` above `newer`, the way a withdrawn queued message rejoins the
  draft the user kept typing.
  """
  @spec merge(Draft.t(), Draft.t()) :: Draft.t()
  def merge(%Draft{} = older, %Draft{} = newer) do
    offset = byte_size(older.text)
    gap = if older.text == "" or newer.text == "", do: "", else: "\n"

    %Draft{
      text: older.text <> gap <> newer.text,
      spans: older.spans ++ shift_spans(newer.spans, offset + byte_size(gap), nil)
    }
  end

  @doc """
  Resolves a draft into the prompt to send.

  Splices in the content behind each of the draft's elements and measures the
  result. Returns `{:error, {:missing_pastes, labels}}` when an element names a
  payload the session no longer holds — the draft is then kept rather than sent
  with a label standing in for its content — and `{:error,
  {:prompt_too_long, chars}}` when the expanded prompt is past
  `max_prompt_chars/0`.
  """
  @spec resolve(Draft.t(), State.t()) ::
          {:ok, String.t()}
          | {:error, {:missing_pastes, [String.t()]} | {:prompt_too_long, pos_integer()}}
  def resolve(%Draft{} = draft, %State{} = state) do
    case missing(draft, state) do
      [] ->
        prompt = draft |> expand(state) |> String.trim()
        chars = String.length(prompt)

        if chars > @max_prompt_chars,
          do: {:error, {:prompt_too_long, chars}},
          else: {:ok, prompt}

      labels ->
        {:error, {:missing_pastes, labels}}
    end
  end

  @doc """
  The draft as text to edit outside the composer, and the labels it keeps.

  A collapsed text paste is spliced back in, since the point of opening an
  editor is to see and change the whole prompt. An image label stays as
  written, because what it stands for is an instruction rather than prose;
  so does a label whose payload is gone, which submission still has to refuse.
  Each kept label comes with its byte offset in the returned text, which is
  what `reattach/2` goes by.
  """
  @spec editable(Draft.t(), State.t()) :: {String.t(), [kept_label()]}
  def editable(%Draft{text: text, spans: spans}, %State{} = state) do
    pastes = pastes(state)

    {parts, kept, cursor, _size} =
      Enum.reduce(spans, {[], [], 0, 0}, fn {id, start, stop}, {parts, kept, cursor, size} ->
        before = binary_part(text, cursor, start - cursor)
        size = size + byte_size(before)
        parts = [parts, before]

        case Map.get(pastes, id) do
          %Paste{kind: :text, content: content} ->
            {[parts, content], kept, stop, size + byte_size(content)}

          _image_or_missing ->
            label = binary_part(text, start, stop - start)
            {[parts, label], [{id, label, size} | kept], stop, size + byte_size(label)}
        end
      end)

    body = IO.iodata_to_binary([parts, binary_part(text, cursor, byte_size(text) - cursor)])
    {body, Enum.reverse(kept)}
  end

  @typedoc "A label `editable/2` kept: its payload id, its text, and its byte offset."
  @type kept_label :: {id :: non_neg_integer(), label :: String.t(), offset :: non_neg_integer()}

  @doc """
  Turns edited text back into a draft, reattaching the labels `editable/2` kept.

  Each kept label claims the unclaimed occurrence of its text nearest to where
  it was, so a label the user moved still stands for its payload, and the same
  text inside an expanded paste does not take its place. A label the user
  deleted is simply gone. Only labels the draft held when it was handed out can
  come back; other label-shaped text stays ordinary prose.
  """
  @spec reattach(String.t(), [kept_label()]) :: Draft.t()
  def reattach(text, labels) when is_binary(text) and is_list(labels) do
    {spans, _claimed} =
      labels
      |> Enum.reject(fn {_id, label, _offset} -> label == "" end)
      |> Enum.reduce({[], MapSet.new()}, fn {id, label, offset}, {spans, claimed} ->
        text
        |> :binary.matches(label)
        |> Enum.reject(fn {start, _length} -> MapSet.member?(claimed, start) end)
        |> Enum.min_by(fn {start, _length} -> abs(start - offset) end, fn -> nil end)
        |> case do
          nil -> {spans, claimed}
          {start, length} -> {[{id, start, start + length} | spans], MapSet.put(claimed, start)}
        end
      end)

    Draft.new(text, Enum.sort_by(spans, fn {_id, start, _stop} -> start end))
  end

  @doc "Collapses retained paste contents in transcript previews."
  @spec collapse(String.t(), State.t()) :: String.t()
  def collapse(text, state) when is_binary(text) do
    state
    |> pastes()
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.uniq_by(& &1.content)
    |> Enum.reject(&(&1.content == ""))
    |> Enum.sort_by(&(-byte_size(&1.content)))
    |> Enum.reduce(text, fn paste, acc ->
      acc
      |> String.replace(paste.content, paste.display)
      |> String.replace(String.trim(paste.content), paste.display)
    end)
  end

  # The prompt to send: every element replaced by what its payload holds.
  defp expand(%Draft{text: text, spans: []}, _state), do: text

  defp expand(%Draft{text: text, spans: spans}, state) do
    pastes = pastes(state)

    {body, cursor} =
      Enum.reduce(spans, {"", 0}, fn {id, start, stop}, {acc, cursor} ->
        paste = Map.fetch!(pastes, id)
        acc = acc <> binary_part(text, cursor, start - cursor) <> paste.content
        {acc, stop}
      end)

    body <> binary_part(text, cursor, byte_size(text) - cursor)
  end

  # Elements whose payload the session does not hold. Their labels are what
  # would otherwise reach the model as though they were the paste.
  defp missing(%Draft{text: text, spans: spans}, state) do
    pastes = pastes(state)

    spans
    |> Enum.reject(fn {id, _start, _stop} -> Map.has_key?(pastes, id) end)
    |> Enum.map(fn {_id, start, stop} -> binary_part(text, start, stop - start) end)
  end

  defp next_label(state, :image, _content) do
    used = used_labels(state)
    number = Enum.find(1..(MapSet.size(used) + 1), &(not MapSet.member?(used, image_label(&1))))
    image_label(number)
  end

  defp next_label(state, :text, content) do
    used = used_labels(state)
    base = text_label(String.length(content))

    if MapSet.member?(used, base) do
      base <> " #" <> Integer.to_string(highest_suffix(used, base) + 1)
    else
      base
    end
  end

  defp image_label(number), do: "[Image ##{number}]"
  defp text_label(chars), do: "[Pasted Content #{chars} chars]"

  # An image preview names the file it stands for; a text preview carries the
  # size the label already reports.
  defp display(:image, label, source) when is_binary(source) and source != "",
    do: label <> " " <> Path.basename(source)

  defp display(_kind, label, _source), do: label

  # Labels are separated from the prose around them, but an empty draft and a
  # draft that already ends in whitespace need no separator.
  defp label_prefix(""), do: ""
  defp label_prefix(draft), do: if(String.ends_with?(draft, [" ", "\n", "\t"]), do: "", else: " ")

  # Labels already spoken for, by the draft or by this session's retained
  # contents. Numbering runs across the session, so a label in a transcript
  # always names the same payload.
  defp used_labels(state) do
    live =
      state
      |> draft()
      |> labels()

    archived = state |> pastes() |> Map.values() |> Enum.map(& &1.label)

    MapSet.new(live ++ archived)
  end

  defp labels(%Draft{text: text, spans: spans}) do
    Enum.map(spans, fn {_id, start, stop} -> binary_part(text, start, stop - start) end)
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

  # Moves spans by `shift` bytes and drops the ones that no longer fit `limit`
  # (`nil` while the caller still has to measure the text).
  defp shift_spans(spans, shift, limit) do
    Enum.flat_map(spans, fn {id, start, stop} ->
      {start, stop} = {start + shift, stop + shift}

      cond do
        stop <= 0 -> []
        is_integer(limit) and start >= limit -> []
        true -> [{id, max(start, 0), maybe_min(stop, limit)}]
      end
    end)
  end

  defp maybe_min(stop, nil), do: stop
  defp maybe_min(stop, limit), do: min(stop, limit)

  defp pastes(state) when is_map(state), do: Map.get(state, :pastes, %{})
end

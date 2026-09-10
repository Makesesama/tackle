defmodule Tackle.CLI.Keybinds do
  @moduledoc """
  The shell's key binding table.

  Every chord the TUI understands is declared here, as a function head that
  pattern matches on `ExRatatui.Event.Key` and resolves to an *intent*: a small
  value saying what the user asked for. `Tackle.CLI.TUI` keeps the behaviour
  for each intent, so bindings can be read, changed, and tested without
  touching view or session logic.

  Each context gets its own resolver—`global/1` for chords that are live
  everywhere, then `base/2`, `transcript/1`, `confirm/1`, `picker/1`,
  `inspector/1`, and `search/1`—and clauses are tried in order, so more
  specific chords must be listed before their unmodified keys.

  Modifier lists arrive in ExRatatui's canonical order (`"shift"`, `"ctrl"`,
  `"alt"`, ...), which lets chords match on them literally:

      defp composer(%Key{code: "n", modifiers: ["alt"]}), do: :new_session

  Bindings that should be live regardless of the modifier list's extras use the
  `is_ctrl` and `is_alt` guards.
  """

  alias ExRatatui.Event.Key

  @typedoc """
  What a chord means in the current context.

  `Tackle.CLI.TUI` decides the behaviour; unknown chords resolve to `:ignore`
  (do nothing, do not render) or `:composer` (let the textarea handle them).
  """
  @type intent ::
          :accept
          | :backspace
          | :browse
          | :cancel
          | :close
          | :composer
          | :confirm
          | :copy_arguments
          | :copy_source
          | :copy_transcript
          | :escape
          | :ignore
          | :inspect
          | :leave
          | :model_picker
          | :new_session
          | :newline
          | :next
          | :page_down
          | :page_up
          | :previous
          | :quit
          | :scroll_end
          | :scroll_start
          | :search
          | :settings_picker
          | :submit
          | :thinking_picker
          | :toggle_thinking
          | :unbound
          | {:adjacent, String.t()}
          | {:input, String.t()}
          | {:insert, String.t()}
          | {:scroll, String.t()}
          | {:transcript, intent()}

  # Ctrl and Alt chords are accepted with or without Shift, matching how
  # terminals report them; any other modifier combination is a different chord.
  defguardp is_ctrl(modifiers) when modifiers in [["ctrl"], ["shift", "ctrl"]]
  defguardp is_alt(modifiers) when modifiers in [["alt"], ["shift", "alt"]]

  # -- global --------------------------------------------------------------

  @doc """
  Resolves chords that stay live in every context, overlays included.

  Returns `:quit` for Ctrl+C, or `:unbound` when the caller should keep
  dispatching in its own context.
  """
  @spec global(Key.t()) :: :quit | :unbound
  def global(%Key{code: "c", modifiers: modifiers}) when is_ctrl(modifiers), do: :quit
  def global(%Key{}), do: :unbound

  @doc """
  Whether a held key may repeat.

  Repeating makes sense for scrolling and moving, not for chords that commit,
  leave, or open something.
  """
  @spec repeatable?(Key.t()) :: boolean()
  def repeatable?(%Key{code: code}) when code in ["esc", "enter", "f1", "f2", "f3", "f4"],
    do: false

  def repeatable?(%Key{code: code, modifiers: modifiers})
      when is_ctrl(modifiers) and code in ["c", "f", "t", "j", "home", "end"],
      do: false

  def repeatable?(%Key{}), do: true

  # -- base (no overlay) ---------------------------------------------------

  @doc """
  Resolves a chord while no overlay is open.

  Function keys open the palettes from the composer and the transcript browser
  alike; every other chord depends on which pane has `focus`. Transcript chords
  come back wrapped as `{:transcript, intent}` so the caller can route them.
  """
  @spec base(Key.t(), atom()) :: intent
  def base(%Key{code: "f1"}, _focus), do: :model_picker
  def base(%Key{code: "f2"}, _focus), do: :thinking_picker
  def base(%Key{code: "f3"}, _focus), do: :settings_picker
  def base(%Key{code: "f4"}, _focus), do: :browse

  def base(key, :transcript), do: {:transcript, transcript(key)}
  def base(key, _composer), do: composer(key)

  # -- composer ------------------------------------------------------------

  defp composer(%Key{code: "esc"}), do: :escape
  defp composer(%Key{code: "n", modifiers: modifiers}) when is_alt(modifiers), do: :new_session
  defp composer(%Key{code: "f", modifiers: modifiers}) when is_ctrl(modifiers), do: :search

  defp composer(%Key{code: "t", modifiers: modifiers}) when is_ctrl(modifiers),
    do: :toggle_thinking

  defp composer(%Key{code: "home", modifiers: modifiers}) when is_ctrl(modifiers),
    do: :scroll_start

  defp composer(%Key{code: "end", modifiers: modifiers}) when is_ctrl(modifiers), do: :scroll_end

  defp composer(%Key{code: code, modifiers: modifiers})
       when is_ctrl(modifiers) and code in ["j", "enter"], do: :newline

  defp composer(%Key{code: "page_up", modifiers: []}), do: :page_up
  defp composer(%Key{code: "page_down", modifiers: []}), do: :page_down
  defp composer(%Key{code: "enter", modifiers: []}), do: :submit
  defp composer(%Key{code: "enter"}), do: :newline
  defp composer(%Key{}), do: :composer

  # -- transcript browser --------------------------------------------------

  @doc """
  Resolves a chord while the transcript browser has focus.

  Reading is what the browser is for, so only the chords that help you read
  stay live. Typing is off, and every other key is `:ignore`.
  """
  @spec transcript(Key.t()) :: intent
  def transcript(%Key{code: "esc"}), do: :leave
  def transcript(%Key{code: "up"}), do: :previous
  def transcript(%Key{code: "p"}), do: :previous
  def transcript(%Key{code: "down"}), do: :next
  def transcript(%Key{code: "n"}), do: :next
  def transcript(%Key{code: "page_up"}), do: :page_up
  def transcript(%Key{code: "page_down"}), do: :page_down
  def transcript(%Key{code: "enter"}), do: :inspect
  def transcript(%Key{code: "i"}), do: :inspect
  def transcript(%Key{code: "y"}), do: :copy_source
  def transcript(%Key{code: "Y"}), do: :copy_source
  def transcript(%Key{code: "a"}), do: :copy_transcript
  def transcript(%Key{code: "A"}), do: :copy_transcript
  def transcript(%Key{code: "f", modifiers: modifiers}) when is_ctrl(modifiers), do: :search

  def transcript(%Key{code: "t", modifiers: modifiers}) when is_ctrl(modifiers),
    do: :toggle_thinking

  def transcript(%Key{}), do: :ignore

  # -- confirmations -------------------------------------------------------

  @doc """
  Resolves a chord inside a yes/no confirmation.
  """
  @spec confirm(Key.t()) :: :confirm | :cancel | :ignore
  def confirm(%Key{code: "y"}), do: :confirm
  def confirm(%Key{code: "Y"}), do: :confirm
  def confirm(%Key{code: "enter"}), do: :confirm
  def confirm(%Key{code: "n"}), do: :cancel
  def confirm(%Key{code: "N"}), do: :cancel
  def confirm(%Key{code: "esc"}), do: :cancel
  def confirm(%Key{}), do: :ignore

  # -- pickers -------------------------------------------------------------

  @doc """
  Resolves a chord inside the model, reasoning, or settings picker.
  """
  @spec picker(Key.t()) :: intent
  def picker(%Key{code: "esc"}), do: :close
  def picker(%Key{code: "up"}), do: :previous
  def picker(%Key{code: "down"}), do: :next
  def picker(%Key{code: "enter"}), do: :accept
  def picker(%Key{code: "backspace"}), do: :backspace
  def picker(%Key{code: code, modifiers: []}) when is_binary(code), do: insert(code)
  def picker(%Key{}), do: :ignore

  defp insert(code) do
    if String.length(code) == 1, do: {:insert, code}, else: :ignore
  end

  # -- tool inspector ------------------------------------------------------

  @doc """
  Resolves a chord inside the tool inspector.
  """
  @spec inspector(Key.t()) :: intent
  def inspector(%Key{code: "esc"}), do: :close
  def inspector(%Key{code: "up"}), do: {:scroll, "up"}
  def inspector(%Key{code: "down"}), do: {:scroll, "down"}
  def inspector(%Key{code: "page_up"}), do: {:scroll, "page_up"}
  def inspector(%Key{code: "page_down"}), do: {:scroll, "page_down"}
  def inspector(%Key{code: "home"}), do: {:scroll, "home"}
  def inspector(%Key{code: "end"}), do: {:scroll, "end"}
  def inspector(%Key{code: "y"}), do: :copy_source
  def inspector(%Key{code: "Y"}), do: :copy_source
  def inspector(%Key{code: "left"}), do: {:adjacent, "left"}
  def inspector(%Key{code: "right"}), do: {:adjacent, "right"}
  def inspector(%Key{code: "a"}), do: :copy_arguments
  def inspector(%Key{code: "A"}), do: :copy_arguments
  def inspector(%Key{}), do: :ignore

  # -- transcript search ---------------------------------------------------

  @doc """
  Resolves a chord inside transcript search.

  Anything the input widget understands is passed through as `{:input, code}`.
  """
  @spec search(Key.t()) :: intent
  def search(%Key{code: "esc"}), do: :close
  def search(%Key{code: "enter"}), do: :next
  def search(%Key{code: "down"}), do: :next
  def search(%Key{code: "up"}), do: :previous
  def search(%Key{code: code}) when is_binary(code), do: {:input, code}
  def search(%Key{}), do: :ignore
end

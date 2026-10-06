defmodule Tackle.CLI.Notifications do
  @moduledoc """
  Terminal notification output helpers for the shell.

  Ported from codex-rs `tui/src/notifications`. When a turn finishes while the
  terminal window is unfocused, the shell asks the terminal for the user's
  attention through one of two backends:

    * **OSC 9** (`\e]9;<body>\a`) — terminals that surface OSC 9 as a desktop
      notification (Ghostty, iTerm2, Kitty, WezTerm, Warp). Under tmux the
      sequence is wrapped in a DCS passthrough and its payload escapes ESC
      bytes, so the inner tmux pane cannot terminate the sequence early.
    * **BEL** (`\a`) — the terminal's bell/attention request, used whenever
      OSC 9 support cannot be established.

  Backend detection is environment-based, mirroring codex's
  `terminal-detection`: `TERM_PROGRAM` identifies the terminal unless it
  identifies tmux itself, then terminal-specific variables
  (`GHOSTTY_RESOURCES_DIR`, `WEZTERM_VERSION`, `ITERM_SESSION_ID`,
  `KITTY_WINDOW_ID`, …) and finally `TERM` are consulted. These variables are
  inherited through tmux, so detection keeps working inside a multiplexer.

  The body is untrusted display text like a window title, so it is sanitized
  through `Tackle.CLI.TerminalTitle.sanitize/2` before the sequence is
  emitted. When stdout is not a terminal, no write is needed.
  """

  alias Tackle.CLI.Native
  alias Tackle.CLI.TerminalTitle

  @typedoc "Notification backend."
  @type backend :: :osc9 | :bel

  @typedoc """
  Outcome of a `notify/1` call.

  `:no_visible_content` means sanitization removed every visible character, so
  no sequence was emitted; whether an empty body should still ring the bell is
  a policy decision for callers.
  """
  @type notify_result :: {:ok, TerminalTitle.set_result()} | {:error, term()}

  # Normalized TERM_PROGRAM values (trimmed, lowercased, separators removed)
  # of terminals that map OSC 9 to a desktop notification.
  @osc9_term_programs ~w(ghostty iterm iterm2 itermapp warp warpterminal wezterm kitty)

  @doc """
  Writes a terminal notification for `message`.

  Picks the backend the current terminal supports, sanitizes the body, and
  writes the escape sequence to stdout.
  """
  @spec notify(String.t()) :: notify_result()
  def notify(message) when is_binary(message) do
    if Native.stdout_is_terminal() do
      case TerminalTitle.sanitize(message, :unicode) do
        "" ->
          {:ok, :no_visible_content}

        body ->
          body
          |> sequence(detect(), tmux?())
          |> emit()
      end
    else
      {:ok, :applied}
    end
  end

  @doc """
  Writes `message`; the single seam the interactive shell injects so tests can
  observe notification writes without touching the real terminal.
  """
  @spec write(String.t()) :: notify_result()
  def write(message), do: notify(message)

  @doc """
  Returns the notification backend `env` supports.

  `env` defaults to the process environment and is a parameter so detection
  stays testable.
  """
  @spec detect(map() | nil) :: backend()
  def detect(env \\ System.get_env()) do
    if supports_osc9?(env), do: :osc9, else: :bel
  end

  @doc """
  Returns whether `env` identifies a terminal that maps OSC 9 to a desktop
  notification.

  `TERM_PROGRAM` is authoritative unless it names tmux itself, matching
  codex's detection order; the terminal-specific variables that follow are
  inherited through tmux, so a Ghostty or WezTerm session inside tmux is still
  detected.
  """
  @spec supports_osc9?(map() | nil) :: boolean()
  def supports_osc9?(env \\ System.get_env())

  def supports_osc9?(env) do
    cond do
      identified_term_program?(env) ->
        normalize_term_program(env["TERM_PROGRAM"]) in @osc9_term_programs

      env["GHOSTTY_RESOURCES_DIR"] != nil ->
        true

      env["WEZTERM_VERSION"] != nil ->
        true

      env["ITERM_SESSION_ID"] != nil or env["ITERM_PROFILE"] != nil or
          env["ITERM_PROFILE_NAME"] != nil ->
        true

      env["KITTY_WINDOW_ID"] != nil or kitty_term?(env) ->
        true

      true ->
        false
    end
  end

  @doc "Returns whether `env` says the shell runs inside tmux."
  @spec tmux?(map() | nil) :: boolean()
  def tmux?(env \\ System.get_env()) do
    env["TMUX"] != nil or env["TMUX_PANE"] != nil
  end

  @doc """
  Returns the escape sequence that posts `body` through `backend`.

  `tmux?` wraps an OSC 9 sequence in a DCS passthrough with the payload's ESC
  bytes doubled, mirroring codex's `Osc9Backend`; BEL is unaffected.
  """
  @spec sequence(String.t(), backend(), boolean()) :: binary()
  def sequence(_body, :bel, _tmux?), do: "\a"

  def sequence(body, :osc9, tmux?) do
    if tmux? do
      "\ePtmux;\e" <> osc9(escape_tmux_payload(body)) <> "\e\\"
    else
      osc9(body)
    end
  end

  @doc "Returns the OSC 9 desktop-notification sequence for `body`."
  @spec osc9(String.t()) :: binary()
  def osc9(body) when is_binary(body), do: "\e]9;" <> body <> "\a"

  defp identified_term_program?(env) do
    case env["TERM_PROGRAM"] do
      value when is_binary(value) and value != "" ->
        normalize_term_program(value) != "tmux"

      _other ->
        false
    end
  end

  # Matches codex's normalization: trim, drop space/dash/underscore/dot
  # separators, and lowercase, so `iTerm.app` and `WarpTerminal` compare
  # against the same normalized names.
  defp normalize_term_program(value) do
    value
    |> String.trim()
    |> String.replace(~r/[\s\-_.]/, "")
    |> String.downcase()
  end

  defp kitty_term?(env) do
    case env["TERM"] do
      term when is_binary(term) -> String.contains?(term, "kitty")
      _other -> false
    end
  end

  defp escape_tmux_payload(body), do: String.replace(body, "\e", "\e\e")

  # `IO.binwrite/2` raises on failure rather than returning an error tuple.
  defp emit(sequence) do
    IO.binwrite(:stdio, sequence)
    {:ok, :applied}
  rescue
    reason -> {:error, reason}
  end
end

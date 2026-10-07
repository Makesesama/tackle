defmodule Tackle.CLI.TUI.TerminalBackground do
  @moduledoc """
  Detects the terminal's background color by asking the terminal.

  `Theme.mode/0` otherwise guesses from `COLORFGBG`, which few terminals
  publish, so a light terminal that keeps its palette to itself is styled
  with the dark palette: user messages and cards paint dark grey bands over
  light prose and code highlighting uses the dark token colors. This module
  sends the standard OSC 11 query and classifies the reported color with the
  same weighted luminance the indexed-color heuristic uses.

  The query runs once, from `mount/1` of the interactive shell, at the one
  moment it is safe: crossterm has already put the terminal into raw mode,
  but the event loop is not reading yet. The dance is:

    * park the BEAM's own terminal reader (`ExRatatui.LocalInput`) so the
      reply is not consumed as shell input;
    * spawn `sh -c 'cat > file'` with inherited standard input, so the reply
      is captured into a private temporary file while the shell keeps owning
      its own stdio;
    * write `ESC ] 11 ; ? ESC \\` to the controlling terminal and poll the
      file until it carries a complete reply or the deadline passes;
    * kill the reader's process group, restore the BEAM reader, and clean
      up the temporary directory.

  Every step is best-effort: a missing `sh`, no controlling terminal, a
  terminal that does not answer, or any timeout returns `:unknown` and
  leaves `Theme.mode/0` with its `COLORFGBG` fallback. An explicit
  `TACKLE_THEME` skips the query entirely, and the result is remembered for
  the lifetime of the VM because the terminal's background does not change
  while the shell runs.
  """

  alias Tackle.CLI.TUI.Theme

  @query "\e]11;?\e\\"

  # Terminals report `rgb:` with one to four hex digits per component and
  # terminate the reply with ST or BEL; `rgba:` carries a fourth (alpha)
  # component. Other terminal reports may precede the reply, so the pattern
  # scans instead of anchoring.
  @response ~r/\e\]11;rgba?:([0-9a-fA-F]{1,4})\/([0-9a-fA-F]{1,4})\/([0-9a-fA-F]{1,4})(?:\/[0-9a-fA-F]{1,4})?(?:\e\\|\a)/

  @default_timeout 120
  @poll_interval 10

  @type mode :: :light | :dark

  @doc """
  Queries the terminal and remembers the detected palette mode.

  Returns the remembered `:light` or `:dark`, or `:unknown` when the
  terminal could not be asked or did not answer.
  """
  @spec detect_and_remember() :: mode() | :unknown
  def detect_and_remember do
    case detect() do
      :unknown ->
        :unknown

      mode ->
        :ok = Theme.remember_background(mode)
        mode
    end
  end

  @doc """
  Returns the terminal's reported background as a palette mode.

  Skips the query when `TACKLE_THEME` pins the palette or the platform
  cannot run the reader.
  """
  @spec detect() :: mode() | :unknown
  def detect do
    if pinned?() or not unix?() do
      :unknown
    else
      query()
    end
  end

  @doc """
  Classifies raw terminal reply bytes as a palette mode.

  Returns `nil` when the bytes do not carry a complete OSC 11 reply.
  """
  @spec classify(String.t()) :: mode() | nil
  def classify(data) when is_binary(data) do
    case Regex.run(@response, data) do
      [_, red, green, blue] ->
        rgb = {scale(red), scale(green), scale(blue)}
        if Theme.light_rgb?(rgb), do: :light, else: :dark

      nil ->
        nil
    end
  end

  # -- query ---------------------------------------------------------------

  defp pinned?, do: System.get_env("TACKLE_THEME") in ["light", "dark"]
  defp unix?, do: match?({:unix, _}, :os.type())

  defp query do
    handle = ExRatatui.LocalInput.detach()

    try do
      with_capture_dir(&read_terminal/1)
    rescue
      _error -> :unknown
    after
      ExRatatui.LocalInput.reattach(handle)
    end
  end

  # A fresh directory per query: `mkdir` fails on an existing name, so a
  # predictable path cannot be pre-created and the reply file cannot be
  # redirected through a symlink.
  defp with_capture_dir(fun) do
    dir = Path.join(System.tmp_dir!(), "tackle-" <> random_name())

    case File.mkdir(dir) do
      :ok ->
        try do
          fun.(Path.join(dir, "reply"))
        after
          File.rm_rf(dir)
        end

      _error ->
        :unknown
    end
  end

  defp random_name, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  defp read_terminal(path) do
    case reader(path) do
      nil ->
        :unknown

      port ->
        try do
          write_query()
          await_reply(path, deadline())
        after
          stop_reader(port)
        end
    end
  end

  defp reader(path) do
    case System.find_executable("sh") do
      nil ->
        nil

      sh ->
        # The reader inherits the shell's standard input, so it sees the
        # terminal's reply without owning the port's stdio; the reply lands
        # in a private file instead of being echoed back to the screen.
        Port.open({:spawn_executable, sh}, [:nouse_stdio, {:args, ["-c", "cat > " <> path]}])
    end
  end

  defp write_query do
    case :file.open("/dev/tty", [:raw, :write]) do
      {:ok, tty} ->
        :ok = :file.write(tty, @query)
        :file.close(tty)

      _error ->
        # A shell whose controlling terminal cannot be opened still has its
        # standard output connected to the terminal.
        IO.write(:user, @query)
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + timeout()

  defp timeout,
    do: Application.get_env(:tackle_cli, :terminal_background_timeout, @default_timeout)

  defp await_reply(path, deadline) do
    case File.read(path) do
      {:ok, data} ->
        case classify(data) do
          nil -> wait_or_give_up(path, deadline)
          mode -> mode
        end

      _error ->
        wait_or_give_up(path, deadline)
    end
  end

  defp wait_or_give_up(path, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(@poll_interval)
      await_reply(path, deadline)
    else
      :unknown
    end
  end

  # Port.close/1 does not signal a child that owns its own stdio, so the
  # reader is killed before the port is closed; otherwise it would keep
  # reading the terminal and steal keystrokes from the TUI. Erlang runs
  # spawned children in their own session, so the child's pid is also its
  # process-group id and the negative pid kills the group — the shell and
  # the reader it forked alike.
  defp stop_reader(port) do
    try do
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> :os.cmd(~c"kill -9 -" ++ Integer.to_charlist(os_pid))
        _other -> :ok
      end

      Port.close(port)
    rescue
      _error -> :ok
    end

    drain(port)
  end

  defp drain(port) do
    receive do
      {^port, :closed} -> drain(port)
    after
      0 -> :ok
    end
  end

  # Components arrive with one to four hex digits; scale each to 8 bits so
  # every report format feeds the same luminance classification.
  defp scale(hex) do
    {value, ""} = Integer.parse(hex, 16)
    round(value * 255 / (trunc(:math.pow(2, 4 * byte_size(hex))) - 1))
  end
end

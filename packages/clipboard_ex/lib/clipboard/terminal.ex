defmodule Clipboard.Terminal do
  @moduledoc """
  Copies through the user's terminal rather than the local display server.

  Two transports are used, in this order:

    * **tmux** — inside tmux, `tmux load-buffer -w` hands the text to tmux,
      which forwards it to the most recently active attached client. This only
      happens when `set-clipboard` is not `off` and the client's terminal
      advertises the `Ms` (OSC 52) capability.
    * **OSC 52** — the `ESC ] 52 ; c ; <base64> BEL` escape sequence, wrapped
      in tmux's DCS passthrough when running inside tmux. It is written to
      `/dev/tty`, falling back to standard output.

  Terminals never acknowledge OSC 52, so a successful write only means the
  request was sent. Payloads above 100,000 bytes are refused, because large
  sequences can overwhelm terminals.

  ## Trusted executables

  Copies happen automatically, possibly inside untrusted project directories,
  so `tmux`, `sh`, and `head` are never looked up through the caller's `PATH`.
  Like Codex, only system and package-manager directories are searched (see
  `trusted_directories/1`), and child processes get a `PATH` made of those
  directories alone. Unlike Codex, symlink targets are not verified, and the
  root-managed Nix per-user profile `/etc/profiles/per-user/$USER/bin` is
  included. A tmux installed elsewhere is not used; OSC 52 still is.
  """

  import Bitwise

  alias Clipboard.Environment

  @max_bytes 100_000
  @tmux_timeout 5_000

  @typedoc "Delivers an escape sequence to the terminal."
  @type writer :: (binary() -> :ok | {:error, term()})

  @typedoc "Forwards text through tmux for the given pane."
  @type tmux_copier :: (binary(), String.t() | nil -> :ok | {:error, term()})

  @type attempts :: [{:tmux | :osc52, term()}]

  @doc "The largest payload, in bytes, the terminal transports accept."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Copies `text` through tmux when available, otherwise (or when tmux fails)
  through OSC 52.

  Options:

    * `:writer` - delivers the OSC 52 sequence; defaults to `write_tty/1`.
    * `:tmux` - forwards through tmux; defaults to `tmux_copy/2`.
  """
  @spec copy(binary(), Environment.t(), keyword()) :: :ok | {:error, attempts()}
  def copy(text, %Environment{} = environment, opts \\ []) when is_binary(text) do
    writer = Keyword.get(opts, :writer, &write_tty/1)
    tmux = Keyword.get(opts, :tmux, &tmux_copy/2)

    if environment.tmux do
      with {:error, tmux_reason} <- tmux_forward(text, environment.tmux_pane, tmux),
           {:error, osc52_reason} <- osc52_copy(text, true, writer) do
        {:error, [tmux: tmux_reason, osc52: osc52_reason]}
      end
    else
      case osc52_copy(text, false, writer) do
        :ok -> :ok
        {:error, reason} -> {:error, [osc52: reason]}
      end
    end
  end

  @doc """
  Returns the OSC 52 sequence for `text`, wrapped for tmux passthrough when
  `tmux?` is true.
  """
  @spec osc52(binary(), boolean()) :: {:ok, binary()} | {:error, {:too_large, pos_integer()}}
  def osc52(text, tmux? \\ false) when is_binary(text) and is_boolean(tmux?) do
    with :ok <- check_size(text) do
      encoded = Base.encode64(text)

      if tmux? do
        {:ok, "\ePtmux;\e\e]52;c;" <> encoded <> "\a\e\\"}
      else
        {:ok, "\e]52;c;" <> encoded <> "\a"}
      end
    end
  end

  @doc """
  Writes `sequence` to the controlling terminal (`/dev/tty`), or to standard
  output when there is none or the write fails.
  """
  @spec write_tty(binary()) :: :ok | {:error, term()}
  def write_tty(sequence) when is_binary(sequence) do
    case File.open("/dev/tty", [:write, :raw, :binary]) do
      {:ok, device} ->
        result =
          try do
            :file.write(device, sequence)
          after
            File.close(device)
          end

        if result == :ok, do: :ok, else: IO.binwrite(:stdio, sequence)

      {:error, _reason} ->
        IO.binwrite(:stdio, sequence)
    end
  end

  @doc """
  Forwards `text` to the system clipboard through tmux.

  Uses `tmux load-buffer -w`, targeting the most recently active client
  attached to the session of `pane`. Gives up after five seconds.
  """
  @spec tmux_copy(binary(), String.t() | nil) :: :ok | {:error, term()}
  def tmux_copy(text, pane), do: tmux_copy(text, pane, [])

  @doc false
  # `:directories` replaces the trusted directories and `:timeout` the overall
  # limit; both exist for tests.
  @spec tmux_copy(binary(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def tmux_copy(_text, nil, _opts), do: {:error, :no_tmux_pane}

  def tmux_copy(text, pane, opts) when is_binary(text) and is_binary(pane) do
    directories =
      opts
      |> Keyword.get_lazy(:directories, &trusted_directories/0)
      |> Enum.filter(&File.dir?/1)

    isolated(Keyword.get(opts, :timeout, @tmux_timeout), fn ->
      with {:ok, sh} <- system_executable("sh", directories),
           {:ok, tmux} <- system_executable("tmux", directories) do
        shell = %{sh: sh, tmux: tmux, path: Enum.join(directories, ":")}

        with {:ok, client} <- tmux_target(shell, pane) do
          load_buffer(shell, client, text)
        end
      end
    end)
  end

  @doc """
  The directories searched for `tmux`, `sh`, and `head`, in order.

  Only system and package-manager locations, after Codex's
  `system_executable`, plus the Nix per-user profile for `USER` when it is a
  plain user name. Directories that do not exist are skipped at use.
  """
  @spec trusted_directories(%{optional(String.t()) => String.t()}) :: [String.t()]
  def trusted_directories(env \\ System.get_env()) do
    per_user =
      case Map.get(env, "USER") do
        user when is_binary(user) ->
          if user =~ ~r/\A[A-Za-z_][A-Za-z0-9_.-]*\z/,
            do: ["/etc/profiles/per-user/#{user}/bin"],
            else: []

        nil ->
          []
      end

    ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/run/current-system/sw/bin"] ++
      per_user ++
      ["/nix/var/nix/profiles/default/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
  end

  @doc """
  Picks the tmux client to forward to.

  Each argument is a function returning `{:ok, output}` or `{:error, reason}`
  for the corresponding tmux query:

    * `set_clipboard` - `tmux show-options -gv set-clipboard`
    * `clients` - `list-clients -F "\#{client_activity} \#{client_name}"`
    * `messages` - a one-argument function for `show-messages -T -t client`,
      which lists the client's terminal capabilities.
  """
  @spec choose_client(
          (-> {:ok, String.t()} | {:error, term()}),
          (-> {:ok, String.t()} | {:error, term()}),
          (String.t() -> {:ok, String.t()} | {:error, term()})
        ) :: {:ok, String.t()} | {:error, term()}
  def choose_client(set_clipboard, clients, messages) do
    with {:ok, setting} <- set_clipboard.(),
         :ok <- clipboard_enabled(setting),
         {:ok, listing} <- clients.(),
         {:ok, client} <- most_active_client(listing),
         {:ok, capabilities} <- messages.(client),
         :ok <- osc52_capable(capabilities) do
      {:ok, client}
    end
  end

  # -- helpers -------------------------------------------------------------

  defp osc52_copy(text, tmux?, writer) do
    with {:ok, sequence} <- osc52(text, tmux?) do
      writer.(sequence)
    end
  end

  defp check_size(text) when byte_size(text) > @max_bytes,
    do: {:error, {:too_large, byte_size(text)}}

  defp check_size(_text), do: :ok

  defp tmux_forward(text, pane, tmux) do
    with :ok <- check_size(text), do: tmux.(text, pane)
  end

  # tmux commands and the load-buffer port run in a monitored process: a hung
  # tmux server is cut off by one overall timeout, and a port that dies with
  # `:epipe` (tmux exiting before reading its input) cannot take the caller
  # down through the port link.
  #
  # Killing the process on timeout closes the port, so `head` sees EOF and
  # tmux may still load a truncated buffer; the caller's OSC 52 fallback then
  # sends the full text last. A tmux client stuck on its server socket is left
  # behind.
  defp isolated(timeout, fun) do
    {pid, ref} = spawn_monitor(fn -> exit({:result, fun.()}) end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:result, result}} -> result
      {:DOWN, ^ref, :process, ^pid, reason} -> {:error, {:tmux_failed, reason}}
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        end

        {:error, :tmux_timeout}
    end
  end

  defp clipboard_enabled(setting) do
    if String.trim(setting) == "off",
      do: {:error, :tmux_clipboard_disabled},
      else: :ok
  end

  defp most_active_client(listing) do
    listing
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/\A(\d+) (.+)\z/, line, capture: :all_but_first) do
        [activity, client] -> [{String.to_integer(activity), client}]
        nil -> []
      end
    end)
    |> Enum.max_by(&elem(&1, 0), fn -> nil end)
    |> case do
      nil -> {:error, :no_tmux_client}
      {_activity, client} -> {:ok, client}
    end
  end

  defp osc52_capable(capabilities) do
    capable? =
      capabilities
      |> String.split(~r/\r?\n/)
      |> Enum.any?(fn line ->
        case String.split(line, "Ms: (string) ", parts: 2) do
          [_prefix, sequence] -> String.trim(sequence) != ""
          _ -> false
        end
      end)

    if capable?, do: :ok, else: {:error, :tmux_client_lacks_osc52}
  end

  defp tmux_target(shell, pane) do
    choose_client(
      fn -> run_tmux(shell, ["show-options", "-gv", "set-clipboard"]) end,
      fn ->
        with {:ok, session} <-
               run_tmux(shell, ["display-message", "-p", "-t", pane, "\#{session_id}"]) do
          run_tmux(shell, [
            "list-clients",
            "-t",
            String.trim(session),
            "-F",
            "\#{client_activity} \#{client_name}"
          ])
        end
      end,
      fn client -> run_tmux(shell, ["show-messages", "-T", "-t", client]) end
    )
  end

  # stdout only: tmux warnings must not leak into parsed output, nor reach the
  # BEAM's stderr, where they would corrupt a full-screen terminal UI.
  defp run_tmux(shell, args) do
    case System.cmd(shell.sh, ["-c", ~S("$0" "$@" 2>/dev/null), shell.tmux | args],
           env: [{"PATH", shell.path}]
         ) do
      {output, 0} -> {:ok, output}
      {_output, status} -> {:error, {:tmux_failed, status}}
    end
  rescue
    error -> {:error, {:tmux_failed, Exception.message(error)}}
  end

  # Ports cannot half-close stdin, so `head -c` delivers exactly the payload
  # and closes tmux's input, letting `load-buffer -` finish. A pipeline exits
  # with the status of its last command, so tmux's failures still surface.
  defp load_buffer(shell, client, text) do
    script = ~S(exec 2>/dev/null; head -c "$1" | "$0" load-buffer -w -t "$2" -)

    port =
      Port.open({:spawn_executable, shell.sh}, [
        :binary,
        :exit_status,
        args: ["-c", script, shell.tmux, Integer.to_string(byte_size(text)), client],
        env: [{~c"PATH", String.to_charlist(shell.path)}]
      ])

    Port.command(port, text)
    await_exit(port)
  end

  defp await_exit(port) do
    receive do
      {^port, {:data, _output}} -> await_exit(port)
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, status}} -> {:error, {:tmux_failed, status}}
    end
  end

  defp system_executable(name, directories) do
    Enum.find_value(directories, {:error, {:executable_not_found, name}}, fn directory ->
      path = Path.join(directory, name)

      case File.stat(path) do
        {:ok, %File.Stat{type: :regular, mode: mode}} when (mode &&& 0o111) != 0 -> {:ok, path}
        _other -> nil
      end
    end)
  end
end

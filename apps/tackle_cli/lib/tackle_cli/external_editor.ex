defmodule Tackle.CLI.ExternalEditor do
  @moduledoc """
  Edits text in the user's own editor, the way `git commit` does.

  `edit/2` writes the text to a private temporary file, runs the editor named
  by `$VISUAL` or `$EDITOR` on it, and reads the file back once the editor
  exits. The file carries an extension (`.md` unless the caller asks for
  another) so the editor picks a fitting mode; a caller editing something
  else, such as a Lua workflow script, passes its own.

  The editor command runs through `/bin/sh`, as git runs it, so values such as
  `code --wait` or `emacsclient -t` work. The file path is passed as a
  separate argument rather than spliced into the command, so no path can be
  read as shell syntax.

  The editor inherits the BEAM's standard streams, which lets a terminal editor
  draw on the user's terminal. Making that terminal usable, for example by
  leaving a fullscreen interface first, is the caller's job; see
  `Tackle.CLI.TUI.ExternalEditor`.
  """

  @typedoc """
  Why an edit produced no text.

    * `:no_editor`: neither `$VISUAL` nor `$EDITOR` names a command.
    * `{:exit_status, status}`: the editor exited unsuccessfully, which is
      how editors report an abandoned edit (`:cq` in Vim).
    * `:no_status`: the shell running the editor ended without reporting how
      the editor exited, for example because no terminal could be opened.
    * `:invalid_utf8`: the saved file is not UTF-8 text.
    * `{:file, reason}`: the temporary file could not be written or read.
    * `{:spawn, reason}`: the editor could not be started.
  """
  @type error ::
          :no_editor
          | {:exit_status, non_neg_integer()}
          | :no_status
          | :invalid_utf8
          | {:file, File.posix()}
          | {:spawn, term()}

  @typedoc "Runs `command` on the file at `path` and waits for it to exit."
  @type runner :: (command :: String.t(), path :: Path.t() -> :ok | {:error, error()})

  @doc """
  The editor command the environment names.

  `$VISUAL` wins over `$EDITOR`, and a blank value counts as unset.
  """
  @spec command(%{optional(String.t()) => String.t()}) :: {:ok, String.t()} | {:error, :no_editor}
  def command(env \\ System.get_env()) when is_map(env) do
    ["VISUAL", "EDITOR"]
    |> Enum.map(&(env |> Map.get(&1, "") |> String.trim()))
    |> Enum.find(&(&1 != ""))
    |> case do
      nil -> {:error, :no_editor}
      command -> {:ok, command}
    end
  end

  @doc """
  Opens `text` in an editor and returns the saved text.

  The temporary file sits in a directory of its own that only the user can
  read, and the directory goes afterwards, whatever the outcome, together with
  any swap or backup files the editor left next to the file. The returned text is the file exactly as saved; the
  caller decides whether, for example, to trim the newline editors append.

  ## Options

    * `:command` - the editor command; defaults to `command/0`.
    * `:extension` - the temporary file's extension; defaults to `".md"`.
    * `:run` - the `t:runner/0` that runs the editor; defaults to `run/2`.
      Tests pass a function that edits the file instead.
  """
  @spec edit(String.t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def edit(text, opts \\ []) when is_binary(text) and is_list(opts) do
    run = Keyword.get(opts, :run, &run/2)
    extension = Keyword.get(opts, :extension, ".md")

    with {:ok, command} <- command_option(opts) do
      with_file(text, extension, fn path ->
        with :ok <- run.(command, path) do
          read(path)
        end
      end)
    end
  end

  defp command_option(opts) do
    case Keyword.fetch(opts, :command) do
      {:ok, command} when is_binary(command) -> {:ok, command}
      :error -> command()
    end
  end

  @doc """
  Runs `command` on `path` on the user's terminal and waits for it to exit.

  The editor starts the way a shell would start it: in this process's session,
  with the terminal as its standard streams. An Erlang port cannot do that,
  because ports start children in a session of their own. A terminal editor
  that opens `/dev/tty` (Emacs, for one) then has no terminal to open.

  The BEAM reaps exited children itself, so the editor's exit status cannot be
  waited for. Instead the wrapping shell prints it on a pipe that
  `Tackle.CLI.Native.run_in_terminal/1` reads; the editor's own output goes to
  `terminal`. The calling process blocks until the editor exits, however long
  the user takes.

  `terminal` is the device the editor writes to: the controlling terminal
  unless a test passes another.
  """
  @spec run(String.t(), Path.t(), Path.t()) :: :ok | {:error, error()}
  def run(command, path, terminal \\ "/dev/tty")
      when is_binary(command) and is_binary(path) and is_binary(terminal) do
    # The command is shell text by design, like git's `$EDITOR`; the file and
    # the terminal are positional arguments, so neither is parsed as syntax.
    script = ~s(exec 3>&1 >"$2"; #{command} "$1" 3>&-; printf '%d' "$?" >&3)

    case Tackle.CLI.Native.run_in_terminal(["/bin/sh", "-c", script, "sh", path, terminal]) do
      {:ok, output} -> exit_status(output)
      {:error, reason} -> {:error, {:spawn, reason}}
    end
  end

  defp exit_status(output) do
    case Integer.parse(output) do
      {0, ""} -> :ok
      {status, ""} -> {:error, {:exit_status, status}}
      _no_status -> {:error, :no_status}
    end
  end

  # A fresh directory per edit: `mkdir` fails on an existing name, so the path
  # cannot be one planted ahead of time, and it is made private before the
  # text goes in. Editors keep swap, backup, and lock files next to the file
  # they edit, so those are private too and go with the directory.
  defp with_file(text, extension, fun) do
    dir = Path.join(System.tmp_dir!(), "tackle-edit-" <> random_name())

    case File.mkdir(dir) do
      :ok ->
        try do
          path = Path.join(dir, "draft" <> extension)

          with :ok <- File.chmod(dir, 0o700),
               :ok <- File.write(path, text, [:exclusive]),
               :ok <- File.chmod(path, 0o600) do
            fun.(path)
          else
            {:error, reason} -> {:error, {:file, reason}}
          end
        after
          File.rm_rf(dir)
        end

      {:error, reason} ->
        {:error, {:file, reason}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> if String.valid?(text), do: {:ok, text}, else: {:error, :invalid_utf8}
      {:error, reason} -> {:error, {:file, reason}}
    end
  end

  defp random_name, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end

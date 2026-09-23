defmodule Tackle.CLI.TUI.ClipboardPaste do
  @moduledoc false

  alias Tackle.CLI.ImageClipboard
  alias Tackle.CLI.TUI.{Composer, State}

  @max_bytes 5 * 1024 * 1024

  @doc "Requests one clipboard image from the host channel; never transfers bytes over it."
  @spec request(String.t()) :: :ok | {:error, term()}
  def request(command) do
    # The host may spend five seconds checking types and five more reading
    # bytes. Allow both to finish before the FIFO reader is interrupted.
    case System.cmd("timeout", ["30s", command, "paste"], stderr_to_stdout: true) do
      {"ok\n", 0} -> :ok
      {_output, _status} -> {:error, :host_clipboard_unavailable}
    end
  rescue
    _ -> {:error, :host_clipboard_unavailable}
  end

  # The host publishes complete files with an atomic rename. The channel
  # carries only an intent and a status; image bytes travel over this RO mount.
  @spec poll(State.t()) :: State.t()
  def poll(%State{clipboard_paste_dir: nil} = state), do: state
  def poll(%State{overlay: overlay} = state) when not is_nil(overlay), do: state
  def poll(%State{focus: focus} = state) when focus != :composer, do: state

  def poll(%State{} = state) do
    case next_image(state.clipboard_paste_dir, state.clipboard_paste_last) do
      {:ok, name} ->
        # Mark even invalid files handled; don't repeatedly surface an error.
        state = %{state | clipboard_paste_last: name}
        path = Path.join(state.clipboard_paste_dir, name)

        with {:ok, %{type: :regular, size: size}} when size <= @max_bytes <- File.lstat(path),
             {:ok, bytes} <- File.read(path),
             :ok <- ImageClipboard.validate_size(bytes),
             {:ok, saved} <- ImageClipboard.save(bytes) do
          %{state | image_paths: [saved | state.image_paths]}
          |> Composer.paste_image(saved)
        else
          _ -> %{state | notice: "Host clipboard image paste failed · draft kept"}
        end

      _ ->
        state
    end
  end

  defp next_image(dir, last) do
    case File.ls(dir) do
      {:ok, names} ->
        case names
             |> Enum.filter(&(Regex.match?(~r/^image-[0-9]+-[0-9]+\.png$/, &1) and &1 > last))
             |> Enum.min(fn -> nil end) do
          nil -> :none
          name -> {:ok, name}
        end

      _ ->
        :none
    end
  end
end

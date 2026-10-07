defmodule Tackle.CLI.ImageClipboard do
  @moduledoc """
  Reads a supported image from the OS clipboard and saves it for the CLI agent.

  Images are deliberately represented in the prompt by a path, not attached to
  the submitted user message. They are saved through the session's executor so
  the agent's `Tackle.Tools.Read` tool can open them, including inside a jail.
  The file is kept until the TUI exits.
  """

  alias Tackle.Executor

  @max_bytes 5 * 1024 * 1024
  @mime_types ["image/png", "image/jpeg", "image/gif", "image/webp"]

  @doc "Reads clipboard image bytes on Linux or macOS, preferring native clipboard utilities."
  @spec read() :: {:ok, binary()} | {:error, term()}
  def read do
    case :os.type() do
      {:unix, :linux} -> read_linux()
      {:unix, :darwin} -> read_pngpaste()
      other -> {:error, {:unsupported_platform, other}}
    end
  end

  @doc "Reads text from the OS clipboard for a Ctrl+V fallback when there is no image."
  @spec read_text() :: {:ok, binary()} | {:error, term()}
  def read_text do
    case :os.type() do
      {:unix, :linux} ->
        cond do
          System.find_executable("wl-paste") ->
            run_clipboard("wl-paste", ["--type", "text/plain;charset=utf-8"])

          System.find_executable("xclip") ->
            run_clipboard("xclip", ["-selection", "clipboard", "-o"])

          true ->
            {:error, :clipboard_unavailable}
        end

      {:unix, :darwin} ->
        if System.find_executable("pbpaste"),
          do: run_clipboard("pbpaste", []),
          else: {:error, :clipboard_unavailable}

      other ->
        {:error, {:unsupported_platform, other}}
    end
  end

  @doc """
  Validates image bytes and writes them to a new owner-only file in the
  executor's temporary directory.
  """
  @spec save(binary(), Executor.t()) :: {:ok, String.t()} | {:error, term()}
  def save(bytes, executor \\ Executor.local()) when is_binary(bytes) do
    with :ok <- validate_size(bytes),
         {:ok, extension} <- image_extension(bytes) do
      write_private(executor, bytes, extension)
    end
  end

  @doc false
  @spec validate_size(binary()) :: :ok | {:error, term()}
  def validate_size(bytes) when byte_size(bytes) <= @max_bytes, do: :ok
  def validate_size(_bytes), do: {:error, :image_too_large}

  @doc false
  @spec image_extension(binary()) :: {:ok, String.t()} | {:error, term()}
  def image_extension(<<137, 80, 78, 71, 13, 10, 26, 10, _::binary>>), do: {:ok, ".png"}
  def image_extension(<<255, 216, 255, _::binary>>), do: {:ok, ".jpg"}
  def image_extension(<<"GIF87a", _::binary>>), do: {:ok, ".gif"}
  def image_extension(<<"GIF89a", _::binary>>), do: {:ok, ".gif"}
  def image_extension(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {:ok, ".webp"}
  def image_extension(_bytes), do: {:error, :unsupported_or_invalid_image}

  defp read_linux do
    cond do
      System.find_executable("wl-paste") ->
        first_clipboard_image(&wl_paste/1)

      System.find_executable("xclip") ->
        first_clipboard_image(&xclip/1)

      true ->
        {:error, :clipboard_unavailable}
    end
  end

  defp first_clipboard_image(reader) do
    Enum.reduce_while(@mime_types, {:error, :no_image_in_clipboard}, fn mime, _acc ->
      case reader.(mime) do
        {:ok, bytes} when byte_size(bytes) > 0 -> {:halt, {:ok, bytes}}
        _ -> {:cont, {:error, :no_image_in_clipboard}}
      end
    end)
  end

  defp wl_paste(mime), do: run_clipboard("wl-paste", ["--type", mime])
  defp xclip(mime), do: run_clipboard("xclip", ["-selection", "clipboard", "-t", mime, "-o"])

  defp read_pngpaste do
    if System.find_executable("pngpaste") do
      case run_clipboard("pngpaste", ["-"]) do
        {:error, _reason} -> {:error, :no_image_in_clipboard}
        result -> result
      end
    else
      {:error, :no_image_in_clipboard}
    end
  end

  defp run_clipboard(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, _status} -> {:error, :no_image_in_clipboard}
    end
  rescue
    error -> {:error, {:clipboard_command_failed, Exception.message(error)}}
  end

  defp write_private(executor, bytes, extension) do
    name =
      "tackle-image-#{Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)}#{extension}"

    path = Path.join(Executor.tmp_dir(executor), name)

    case Executor.write(executor, path, bytes, mode: :create) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end
end

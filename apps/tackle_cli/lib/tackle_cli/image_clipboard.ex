defmodule Tackle.CLI.ImageClipboard do
  @moduledoc """
  Reads images and text from the OS clipboard and saves them for the CLI agent.

  Reading goes through `:clipboard_ex`'s native clipboard, so no external
  utilities (`wl-paste`, `xclip`, `pbpaste`) are required and pasting works
  wherever the CLI runs, including as the host process of a jailed session.
  Images arrive from the clipboard as RGBA pixels and are encoded to PNG
  before they are saved.

  Images are deliberately represented in the prompt by a path, not attached to
  the submitted user message. They are saved through the session's executor so
  the agent's `Tackle.Tools.Read` tool can open them, including inside a jail.
  The file is kept until the TUI exits.
  """

  alias Tackle.Executor

  @max_bytes 5 * 1024 * 1024
  # Reject absurd clipboard images before allocating a PNG encoding of them;
  # ordinary screenshots stay far below this many raw RGBA bytes.
  @max_raw_bytes 64 * 1024 * 1024

  @png_signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  @doc "Reads a clipboard image as PNG bytes, or an error when there is none."
  @spec read() :: {:ok, binary()} | {:error, term()}
  def read, do: read(&Clipboard.read_image/0)

  @doc false
  # The reader is injectable for tests and must return what
  # `Clipboard.read_image/0` returns.
  @spec read((-> {:ok, Clipboard.Image.t()} | {:error, term()})) ::
          {:ok, binary()} | {:error, term()}
  def read(reader) when is_function(reader, 0) do
    case reader.() do
      {:ok, %Clipboard.Image{width: width, height: height, rgba: rgba}} ->
        encode_png(width, height, rgba)

      {:error, :content_not_available} ->
        {:error, :no_image_in_clipboard}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Reads text from the OS clipboard for a Ctrl+V fallback when there is no image."
  @spec read_text() :: {:ok, binary()} | {:error, term()}
  def read_text, do: read_text(&Clipboard.read_text/0)

  @doc false
  @spec read_text((-> {:ok, binary()} | {:error, term()})) ::
          {:ok, binary()} | {:error, term()}
  def read_text(reader) when is_function(reader, 0), do: reader.()

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

  @doc false
  # Encodes RGBA pixels as a PNG, the only clipboard-image format this shell
  # produces. Pure standard library: filter-0 scanlines deflated with zlib.
  @spec encode_png(pos_integer(), pos_integer(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def encode_png(width, height, rgba) when width > 0 and height > 0 do
    stride = width * 4

    with :ok <- validate_pixels(stride, height, rgba),
         :ok <- validate_raw_size(rgba) do
      raw =
        for row <- 0..(height - 1), into: <<>> do
          <<0, :binary.part(rgba, row * stride, stride)::binary>>
        end

      {:ok, @png_signature <> png_chunks(width, height, raw)}
    end
  end

  def encode_png(_width, _height, _rgba), do: {:error, :invalid_image}

  defp validate_pixels(stride, height, rgba) do
    if byte_size(rgba) == stride * height, do: :ok, else: {:error, :invalid_image}
  end

  defp validate_raw_size(rgba) do
    if byte_size(rgba) <= @max_raw_bytes, do: :ok, else: {:error, :image_too_large}
  end

  defp png_chunks(width, height, raw) do
    ihdr = <<width::32-big, height::32-big, 8, 6, 0, 0, 0>>

    png_chunk("IHDR", ihdr) <> png_chunk("IDAT", :zlib.compress(raw)) <> png_chunk("IEND", "")
  end

  defp png_chunk(type, data) do
    crc = :erlang.crc32(type <> data)
    <<byte_size(data)::32-big, type::binary, data::binary, crc::32-big>>
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

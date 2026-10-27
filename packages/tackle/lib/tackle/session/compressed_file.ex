defmodule Tackle.Session.CompressedFile do
  @moduledoc """
  zstd-compressed copies of session files: `session.dlog.zst` beside a
  journal, and recovery copies.

  A compressed file holds the exact bytes of the plain file. The plain file
  is authoritative: a copy is written and verified before the plain file is
  deleted (`replace/3`), and the plain file is written before the copy is
  deleted (`restore/1`), so an interruption leaves at most a redundant copy.
  Every decompression is checked against the original size recorded in the
  zstd frame (zstd itself returns a truncated frame's partial output without
  an error) and against the frame checksum.

  Readers use `with_readable/2`, which replays a compressed journal from a
  private temporary copy; the journal owner restores the plain journal under
  its writer lock before opening it. Deciding what to compress, and when, is
  `Tackle.Session.Compression`'s.
  """

  alias Tackle.Session.Storage

  @level 3
  @read_prefix "session.dlog.read-"

  @doc "Whether zstd compression is available in this runtime (OTP 28 or later)."
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(:zstd)

  @doc """
  Reads the file at `path` and compresses it.

  Returns the compressed bytes and the plain size, once the compressed bytes
  decompress to the same content.
  """
  @spec compress(String.t()) ::
          {:ok, binary(), non_neg_integer()} | {:error, term()}
  def compress(path) do
    with {:ok, plain} <- read(path),
         {:ok, compressed} <- compress_binary(plain),
         {:ok, ^plain} <- decompress(compressed, path) do
      {:ok, compressed, byte_size(plain)}
    else
      {:ok, _different} -> {:error, {:verify_failed, path}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Replaces the plain file at `path` with `compressed`, its compression
  (`compress/1`), at `path <> ".zst"`.

  The copy is written atomically and must decompress to `plain_size` bytes
  before the plain file is deleted. The directory is never created, so a file
  whose directory was moved meanwhile is left alone. On failure the plain file
  stays, and a copy that was written is removed.
  """
  @spec replace(String.t(), binary(), non_neg_integer()) :: :ok | {:error, term()}
  def replace(path, compressed, plain_size) do
    destination = Storage.compressed_path(path)

    with :ok <- Storage.atomic_write(destination, compressed, create_dir: false),
         :ok <- verify_file(destination, path, plain_size),
         :ok <- remove(path) do
      :ok
    else
      {:error, reason} ->
        if File.regular?(path), do: _ = File.rm(destination)
        {:error, reason}
    end
  end

  @doc """
  Replaces `path` with a verified zstd copy at `path <> ".zst"`
  (`compress/1`, then `replace/3`).

  Returns the plain and compressed sizes. Used for recovery copies, which no
  writer appends to.
  """
  @spec compress_file(String.t()) ::
          {:ok, non_neg_integer(), non_neg_integer()} | {:error, term()}
  def compress_file(path) do
    with {:ok, compressed, plain_size} <- compress(path),
         :ok <- replace(path, compressed, plain_size) do
      {:ok, plain_size, byte_size(compressed)}
    end
  end

  @doc """
  Restores the plain journal at `path` from its compressed copy.

  Call it while holding the session's writer lock. A missing compressed copy,
  or a plain journal that already exists, is left alone: the plain journal is
  authoritative, and a leftover compressed copy is removed.
  """
  @spec restore(String.t()) :: :ok | {:error, term()}
  def restore(path) do
    compressed_path = Storage.compressed_path(path)

    cond do
      not File.regular?(compressed_path) ->
        :ok

      File.regular?(path) ->
        remove(compressed_path)

      true ->
        with {:ok, plain} <- decompress_file(compressed_path),
             :ok <- Storage.atomic_write(path, plain) do
          remove(compressed_path)
        end
    end
  end

  @doc """
  Runs `fun` with a readable plain journal for `path`.

  A plain journal is passed through. Otherwise a compressed journal is
  decompressed into a private temporary file beside it (see `read_copy?/1`)
  for the duration of `fun`. A plain journal that is compressed between the
  check and the read is retried from its compressed copy.
  """
  @spec with_readable(String.t(), (String.t() -> result)) :: result | {:error, term()}
        when result: term()
  def with_readable(path, fun) do
    compressed_path = Storage.compressed_path(path)

    cond do
      File.regular?(path) ->
        path |> fun.() |> retry_compressed(path, compressed_path, fun)

      File.regular?(compressed_path) ->
        read_compressed(path, compressed_path, fun)

      true ->
        fun.(path)
    end
  end

  @doc """
  Whether `file_name` is a temporary copy `with_readable/2` decompresses a
  journal into; one left behind by a process that died can be removed.
  """
  @spec read_copy?(String.t()) :: boolean()
  def read_copy?(file_name), do: String.starts_with?(file_name, @read_prefix)

  # The plain journal was compressed between the check and the read.
  defp retry_compressed({:error, _reason} = error, path, compressed_path, fun) do
    if not File.exists?(path) and File.regular?(compressed_path),
      do: read_compressed(path, compressed_path, fun),
      else: error
  end

  defp retry_compressed(result, _path, _compressed_path, _fun), do: result

  defp read_compressed(path, compressed_path, fun) do
    temp = Path.join(Path.dirname(path), @read_prefix <> unique())

    with {:ok, plain} <- decompress_file(compressed_path),
         :ok <- write_private(temp, plain) do
      try do
        fun.(temp)
      after
        _ = File.rm(temp)
      end
    else
      # A writable owner restored the plain journal meanwhile.
      {:error, {:read_failed, ^compressed_path, :enoent}} = error ->
        if File.regular?(path), do: fun.(path), else: error

      {:error, _reason} = error ->
        error
    end
  end

  # The written file is checked for the full original size, which also catches
  # a short write; its content was already verified in memory.
  defp verify_file(compressed_path, path, plain_size) do
    with {:ok, binary} <- read(compressed_path),
         {:ok, plain} <- decompress(binary, path) do
      if byte_size(plain) == plain_size,
        do: :ok,
        else: {:error, {:verify_failed, compressed_path}}
    end
  end

  defp decompress_file(path) do
    with {:ok, compressed} <- read(path), do: decompress(compressed, path)
  end

  # zstd returns a truncated frame's partial output without an error, so the
  # result must match the content size the frame header declares.
  defp decompress(compressed, path) do
    if available?() do
      with {:ok, %{frameContentSize: size}} when is_integer(size) <-
             :zstd.get_frame_header(compressed),
           plain = compressed |> :zstd.decompress() |> IO.iodata_to_binary(),
           ^size <- byte_size(plain) do
        {:ok, plain}
      else
        other -> {:error, {:decompress_failed, path, decompress_reason(other)}}
      end
    else
      {:error, {:zstd_unavailable, path}}
    end
  rescue
    error -> {:error, {:decompress_failed, path, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:decompress_failed, path, {kind, reason}}}
  end

  defp decompress_reason(size) when is_integer(size), do: {:truncated, size}
  defp decompress_reason({:ok, _header}), do: :unknown_content_size
  defp decompress_reason(other), do: other

  defp compress_binary(plain) do
    options = %{compressionLevel: @level, checksumFlag: true}
    {:ok, plain |> :zstd.compress(options) |> IO.iodata_to_binary()}
  rescue
    error -> {:error, {:compress_failed, Exception.message(error)}}
  end

  defp read(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, {:read_failed, path, reason}}
    end
  end

  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:remove_failed, path, reason}}
    end
  end

  defp write_private(path, content) do
    with :ok <- File.write(path, content, [:raw, :exclusive]),
         :ok <- File.chmod(path, Storage.file_mode()) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(path)
        {:error, {:write_failed, path, reason}}
    end
  end

  defp unique, do: Integer.to_string(System.unique_integer([:positive]))
end

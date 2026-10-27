defmodule Tackle.Session.CompressedFileTest do
  use ExUnit.Case, async: true

  import Tackle.Test.Runtime

  alias Tackle.Session.CompressedFile
  alias Tackle.Session.Storage

  unless Code.ensure_loaded?(:zstd), do: @moduletag(skip: "needs :zstd (OTP 28 or later)")

  setup do
    path = Path.join(tmp_home(), "session.dlog")
    File.write!(path, String.duplicate("journal bytes ", 1_000))
    {:ok, path: path, plain: File.read!(path)}
  end

  test "compresses a file it reads and verifies the result", ctx do
    assert {:ok, compressed, size} = CompressedFile.compress(ctx.path)
    assert size == byte_size(ctx.plain)
    assert byte_size(compressed) < size
    assert File.read!(ctx.path) == ctx.plain

    missing = ctx.path <> ".missing"
    assert {:error, {:read_failed, ^missing, :enoent}} = CompressedFile.compress(missing)
  end

  test "replaces a file with its compressed copy and reads it back", ctx do
    {:ok, compressed, size} = CompressedFile.compress(ctx.path)

    assert :ok = CompressedFile.replace(ctx.path, compressed, size)
    refute File.exists?(ctx.path)
    assert File.regular?(Storage.compressed_path(ctx.path))

    assert CompressedFile.with_readable(ctx.path, fn readable ->
             assert CompressedFile.read_copy?(Path.basename(readable))
             File.read!(readable)
           end) == ctx.plain

    # The temporary copy is gone again.
    assert File.ls!(Path.dirname(ctx.path)) == ["session.dlog.zst"]

    assert :ok = CompressedFile.restore(ctx.path)
    assert File.read!(ctx.path) == ctx.plain
    refute File.exists?(Storage.compressed_path(ctx.path))
  end

  test "keeps the plain file when the written copy does not verify", ctx do
    {:ok, compressed, size} = CompressedFile.compress(ctx.path)
    zst = Storage.compressed_path(ctx.path)

    assert {:error, {:verify_failed, ^zst}} =
             CompressedFile.replace(ctx.path, compressed, size + 1)

    assert File.read!(ctx.path) == ctx.plain
    refute File.exists?(zst)
  end

  test "compresses a file in one step, reporting both sizes", ctx do
    assert {:ok, plain_size, compressed_size} = CompressedFile.compress_file(ctx.path)
    assert plain_size == byte_size(ctx.plain)
    assert compressed_size == File.stat!(Storage.compressed_path(ctx.path)).size
    refute File.exists?(ctx.path)
  end

  test "names the temporary copies readers make" do
    assert CompressedFile.read_copy?("session.dlog.read-12")
    refute CompressedFile.read_copy?("session.dlog")
    refute CompressedFile.read_copy?("summary.etf.tmp-3")
  end
end

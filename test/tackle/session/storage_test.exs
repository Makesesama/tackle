defmodule Tackle.Session.StorageTest do
  use ExUnit.Case, async: true

  alias Tackle.Session.Storage

  setup do
    home = Tackle.Test.Runtime.tmp_home()
    {:ok, home: home, session_id: Tackle.Runtime.ID.generate()}
  end

  test "rejects session ids that could escape the storage root", ctx do
    assert {:error, {:invalid_session_id, _}} = Storage.session_dir("../escape", home: ctx.home)
    assert {:error, {:invalid_session_id, _}} = Storage.session_dir("..", home: ctx.home)
    assert {:error, {:invalid_session_id, _}} = Storage.session_dir("a/b", home: ctx.home)
    assert {:ok, _path} = Storage.session_dir(ctx.session_id, home: ctx.home)
  end

  test "creates private session directories", ctx do
    assert {:ok, dir} = Storage.ensure_session_dir(ctx.session_id, home: ctx.home)
    assert File.dir?(dir)
    assert {:ok, %{mode: mode}} = File.stat(dir)
    assert Bitwise.band(mode, 0o777) == 0o700
  end

  test "writes sidecar files atomically", ctx do
    {:ok, dir} = Storage.ensure_session_dir(ctx.session_id, home: ctx.home)
    path = Path.join(dir, "summary.etf")

    assert :ok = Storage.atomic_write(path, :erlang.term_to_binary(%{"value" => 1}))
    assert {:ok, binary} = File.read(path)
    assert :erlang.binary_to_term(binary) == %{"value" => 1}
    assert File.ls!(dir) == ["summary.etf"]
  end

  test "lists only validated session directories", ctx do
    {:ok, _dir} = Storage.ensure_session_dir(ctx.session_id, home: ctx.home)

    root = Path.join(ctx.home, "sessions")
    File.mkdir_p!(Path.join(root, "bad name"))
    File.mkdir_p!(Path.join(root, ".hidden"))
    File.write!(Path.join(root, "stray-file"), "x")

    assert {:ok, session_ids} = Storage.list_session_ids(home: ctx.home)
    assert session_ids == [ctx.session_id]
  end

  test "moves a session directory into the trash", ctx do
    {:ok, dir} = Storage.ensure_session_dir(ctx.session_id, home: ctx.home)
    File.write!(Path.join(dir, "session.dlog"), "data")

    assert {:ok, destination} = Storage.trash_session(ctx.session_id, home: ctx.home)
    assert File.dir?(destination)
    refute File.exists?(dir)
  end

  test "publishes a temporary directory atomically", ctx do
    {:ok, temp} = Storage.temporary_session_dir(home: ctx.home)
    {:ok, final_dir} = Storage.session_dir(ctx.session_id, home: ctx.home)
    File.write!(Path.join(temp, "session.dlog"), "data")

    assert :ok = Storage.publish_directory(temp, final_dir)
    assert File.exists?(Path.join(final_dir, "session.dlog"))
    refute File.exists?(temp)
    assert {:error, _reason} = Storage.publish_directory(temp, final_dir)
  end
end

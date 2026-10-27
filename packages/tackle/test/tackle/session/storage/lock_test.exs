defmodule Tackle.Session.Storage.LockTest do
  @moduledoc false
  # The process-identity fallback is used where `flock` is missing. Clearing
  # PATH forces it, and PATH is global, so these tests run alone.
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Runtime.ID
  alias Tackle.Session.Storage
  alias Tackle.Session.Storage.Lock
  alias Tackle.Test.LegacyJournals

  setup do
    home = tmp_home()
    session_id = ID.generate()
    {:ok, dir} = Storage.ensure_session_dir(session_id, home: home)

    old_path = System.get_env("PATH")
    System.put_env("PATH", "")
    on_exit(fn -> restore_path(old_path) end)

    {:ok, home: home, session_id: session_id, dir: dir}
  end

  test "records the owner in a private lock file and refuses a second owner", ctx do
    assert {:ok, %Lock{port: nil, owner: owner} = lock} = Lock.acquire(ctx.dir)
    assert owner["pid"] == System.pid()
    assert is_binary(owner["process_identity"])

    path = Lock.path(ctx.dir)
    assert JSON.decode!(File.read!(path)) == owner
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600

    assert {:error, {:session_in_use, ^owner}} = Lock.acquire(ctx.dir)

    assert :ok = Lock.release(lock)
    refute File.exists?(path)
    assert {:ok, lock} = Lock.acquire(ctx.dir)
    Lock.release(lock)
  end

  test "Storage takes and releases the fallback lock of a session", ctx do
    assert {:ok, %Lock{port: nil} = lock} = Storage.acquire_lock(ctx.session_id, home: ctx.home)
    assert File.exists?(Lock.path(ctx.dir))
    assert :ok = Storage.release_lock(lock)
    refute File.exists?(Lock.path(ctx.dir))
  end

  test "reclaims the lock of a process that no longer exists", ctx do
    dead = Map.put(Lock.current_owner(), "pid", "999999999")
    File.write!(Lock.path(ctx.dir), JSON.encode!(dead))

    assert {:ok, lock} = Lock.acquire(ctx.dir)
    assert lock.owner["pid"] == System.pid()
    Lock.release(lock)
  end

  test "reclaims the lock of a reused pid whose process identity differs", ctx do
    reused = Map.update!(Lock.current_owner(), "process_identity", &(&1 <> "-earlier"))
    File.write!(Lock.path(ctx.dir), JSON.encode!(reused))

    assert {:ok, lock} = Lock.acquire(ctx.dir)
    assert lock.owner["process_identity"] != reused["process_identity"]
    Lock.release(lock)
  end

  test "reports a stale lock as in use instead of reclaiming it with reclaim: false", ctx do
    dead = Map.put(Lock.current_owner(), "pid", "999999999")
    File.write!(Lock.path(ctx.dir), JSON.encode!(dead))

    assert {:error, {:session_in_use, ^dead}} = Lock.acquire(ctx.dir, reclaim: false)
  end

  describe "a lock file written before locks recorded the process identity" do
    test "is reclaimed when this VM's pid took it before the VM started", ctx do
      File.write!(Lock.path(ctx.dir), LegacyJournals.lock_owner(System.pid(), 0))

      assert {:ok, lock} = Storage.acquire_lock(ctx.session_id, home: ctx.home)
      assert lock.owner["started_at"] > 0
      assert is_binary(lock.owner["process_identity"])
      Storage.release_lock(lock)
    end

    test "is in use when this VM took it", ctx do
      legacy = LegacyJournals.lock_owner(System.pid(), System.system_time(:second))
      File.write!(Lock.path(ctx.dir), legacy)

      assert {:error, {:session_in_use, owner}} = Lock.acquire(ctx.dir)
      assert owner == JSON.decode!(legacy)
    end

    test "is in use while another live process has its pid", ctx do
      File.write!(Lock.path(ctx.dir), LegacyJournals.lock_owner("1", 0))

      assert {:error, {:session_in_use, %{"pid" => "1"}}} = Lock.acquire(ctx.dir)
    end

    test "is reclaimed when its process is gone", ctx do
      File.write!(Lock.path(ctx.dir), LegacyJournals.lock_owner("999999999", 0))

      assert {:ok, lock} = Lock.acquire(ctx.dir)
      Lock.release(lock)
    end
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(path), do: System.put_env("PATH", path)
end

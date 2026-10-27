defmodule Tackle.FileLockTest do
  @moduledoc false
  # Each acquisition through `flock` runs its own `flock` OS process on its
  # own open file, so two Erlang processes excluding each other here is
  # exclusion between two OS processes. `advisory: false` forces the fallback.
  use ExUnit.Case, async: true

  import Bitwise

  alias Tackle.FileLock

  setup do
    dir = Path.join(System.tmp_dir!(), "tackle-file-lock-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{path: Path.join(dir, "test.lock")}
  end

  for {mode, mode_opts} <- [flock: [], fallback: [advisory: false]] do
    describe "with #{mode}" do
      @mode mode
      @mode_opts mode_opts

      test "records the owner in a private lock file", %{path: path} do
        assert {:ok, %FileLock{owner: owner} = lock} = FileLock.acquire(path, @mode_opts)
        assert is_port(lock.port) == (@mode == :flock)
        assert owner["pid"] == System.pid()
        assert JSON.decode!(File.read!(path)) == owner
        assert (File.stat!(path).mode &&& 0o777) == 0o600

        assert :ok = FileLock.release(lock)
        # A flock file is never deleted; the fallback record is.
        assert File.exists?(path) == (@mode == :flock)
      end

      test "a second holder fails at once without waiting", %{path: path} do
        holder = start_holder(path, @mode_opts)
        assert_receive {:acquired, ^holder, {:ok, lock}}

        assert {:error, {:locked, owner}} = FileLock.acquire(path, @mode_opts)
        assert owner["pid"] == lock.owner["pid"]

        release(holder)
        assert {:ok, lock} = FileLock.acquire(path, @mode_opts)
        FileLock.release(lock)
      end

      test "a waiting holder gets the lock once the first releases it", %{path: path} do
        first = start_holder(path, @mode_opts)
        assert_receive {:acquired, ^first, {:ok, _lock}}

        second = start_holder(path, Keyword.put(@mode_opts, :wait, 10_000))
        refute_receive {:acquired, ^second, _result}, 300

        release(first)
        assert_receive {:acquired, ^second, {:ok, _lock}}, 5_000
        release(second)
      end

      test "waiting gives up after the timeout", %{path: path} do
        holder = start_holder(path, @mode_opts)
        assert_receive {:acquired, ^holder, {:ok, _lock}}

        started = System.monotonic_time(:millisecond)
        assert {:error, {:lock_timeout, ^path}} = acquire_waiting(path, @mode_opts, 300)
        assert System.monotonic_time(:millisecond) - started >= 300

        release(holder)
        assert {:ok, lock} = acquire_waiting(path, @mode_opts, 300)
        FileLock.release(lock)
      end

      test "the lock is released when its holder dies", %{path: path} do
        holder = start_holder(path, @mode_opts)
        assert_receive {:acquired, ^holder, {:ok, _lock}}

        Process.exit(holder, :kill)
        assert {:ok, lock} = acquire_waiting(path, @mode_opts, 5_000)
        FileLock.release(lock)
      end

      test "with_lock/3 runs the function under the lock and releases it", %{path: path} do
        assert {:ok, :done} =
                 FileLock.with_lock(path, @mode_opts, fn ->
                   assert {:error, {:locked, _owner}} = FileLock.acquire(path, @mode_opts)
                   :done
                 end)

        assert_raise RuntimeError, fn ->
          FileLock.with_lock(path, @mode_opts, fn -> raise "boom" end)
        end

        assert catch_throw(FileLock.with_lock(path, @mode_opts, fn -> throw(:thrown) end)) ==
                 :thrown

        assert {:ok, lock} = FileLock.acquire(path, @mode_opts)

        assert {:error, {:locked, _owner}} =
                 FileLock.with_lock(path, @mode_opts, fn -> flunk("ran without the lock") end)

        FileLock.release(lock)
      end
    end
  end

  describe "the fallback" do
    test "keeps a record whose holder died with process_bound: false", %{path: path} do
      opts = [advisory: false, process_bound: false]
      holder = start_holder(path, opts)
      assert_receive {:acquired, ^holder, {:ok, lock}}

      Process.exit(holder, :kill)
      assert {:error, {:locked, owner}} = FileLock.acquire(path, advisory: false)
      assert owner == lock.owner

      assert :ok = FileLock.release(lock)
      assert {:ok, lock} = FileLock.acquire(path, advisory: false)
      FileLock.release(lock)
    end

    test "reclaims the record of an OS process that no longer exists", %{path: path} do
      dead = Map.put(FileLock.current_owner(), "pid", "999999999")
      File.write!(path, JSON.encode!(dead))

      assert {:error, {:locked, ^dead}} = FileLock.acquire(path, advisory: false, reclaim: false)
      assert {:ok, lock} = FileLock.acquire(path, advisory: false)
      assert lock.owner["pid"] == System.pid()
      FileLock.release(lock)
    end
  end

  defp acquire_waiting(path, opts, timeout),
    do: FileLock.acquire(path, Keyword.put(opts, :wait, timeout))

  # Takes the lock in a separate process, which holds it until told to
  # release it.
  defp start_holder(path, opts) do
    test = self()

    spawn(fn ->
      result = FileLock.acquire(path, opts)
      send(test, {:acquired, self(), result})

      receive do
        :release ->
          {:ok, lock} = result
          FileLock.release(lock)
          send(test, {:released, self()})
      end
    end)
  end

  defp release(holder) do
    send(holder, :release)
    assert_receive {:released, ^holder}, 5_000
  end
end

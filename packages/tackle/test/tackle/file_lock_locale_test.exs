defmodule Tackle.FileLockLocaleTest do
  @moduledoc false
  # Changes the OS environment, which every port inherits, so it cannot run
  # alongside other tests. Only meaningful where a decimal-comma locale such as
  # `de_DE.UTF-8` is installed; elsewhere glibc falls back to `C`.
  use ExUnit.Case, async: false

  alias Tackle.FileLock

  setup do
    dir = Path.join(System.tmp_dir!(), "tackle-file-lock-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = System.get_env("LC_ALL")
    System.put_env("LC_ALL", "de_DE.UTF-8")

    on_exit(fn ->
      if previous, do: System.put_env("LC_ALL", previous), else: System.delete_env("LC_ALL")
      File.rm_rf(dir)
    end)

    %{path: Path.join(dir, "test.lock")}
  end

  test "a waiting acquire works under a decimal-comma locale", %{path: path} do
    assert {:ok, lock} = FileLock.acquire(path, wait: 60_000)
    assert is_port(lock.port) == is_binary(System.find_executable("flock"))
    FileLock.release(lock)
  end
end

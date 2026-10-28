defmodule Tackle.Auth.StoreTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Tackle.Auth.Store
  alias Tackle.FileLock
  alias Tackle.Lib.CredentialStore

  setup do
    home = Path.join(System.tmp_dir!(), "tackle-auth-#{System.unique_integer([:positive])}")
    path = Path.join(home, "auth.json")
    on_exit(fn -> File.rm_rf(home) end)
    %{home: home, path: path}
  end

  test "missing file behaves as an empty store", %{path: path} do
    store = start_store(path)
    assert :error = Store.fetch(store, "openai-codex")
    assert :missing = Store.status(store, "openai-codex")
    refute File.exists?(path)
  end

  test "round-trips opaque provider credentials through the neutral helper", %{path: path} do
    store = start_store(path)
    handle = {Store, store}
    credentials = %{"access_token" => "secret-token", "expires_at" => 123}

    assert :ok = CredentialStore.put(handle, "openai-codex", credentials)
    assert {:ok, ^credentials} = CredentialStore.fetch(handle, "openai-codex")
    assert :stored = Store.status(store, "openai-codex")
  end

  test "updating and deleting one provider preserves other providers", %{path: path} do
    store = start_store(path)

    assert :ok = Store.put(store, "provider-a", %{"token" => "a1"})
    assert :ok = Store.put(store, "provider-b", %{"token" => "b"})
    assert :ok = Store.put(store, "provider-a", %{"token" => "a2"})
    assert :ok = Store.delete(store, "provider-a")

    assert :error = Store.fetch(store, "provider-a")
    assert {:ok, %{"token" => "b"}} = Store.fetch(store, "provider-b")

    envelope = path |> File.read!() |> JSON.decode!()

    assert envelope == %{
             "version" => 2,
             "providers" => %{"provider-b" => %{"token" => "b"}},
             "accounts" => %{}
           }
  end

  test "malformed files are actionable and never overwritten", %{home: home, path: path} do
    File.mkdir_p!(home)
    contents = ~s({"version":1,"providers":{"openai-codex":{"token":"do-not-leak"}})
    File.write!(path, contents)

    result = start_store_error(path)
    assert {:error, {:malformed_auth_file, ^path}} = result
    assert File.read!(path) == contents
    refute inspect(result) =~ "do-not-leak"
  end

  test "unsupported versions fail safely", %{home: home, path: path} do
    File.mkdir_p!(home)
    File.write!(path, JSON.encode!(%{"version" => 3, "providers" => %{}}))

    assert {:error, {:unsupported_auth_version, ^path, 3}} = start_store_error(path)
  end

  test "a version 1 file loads with no accounts and is rewritten as version 2", %{
    home: home,
    path: path
  } do
    File.mkdir_p!(home)

    File.write!(
      path,
      JSON.encode!(%{"version" => 1, "providers" => %{"openai-codex" => %{"token" => "v1"}}})
    )

    store = start_store(path)
    assert {:ok, %{"token" => "v1"}} = Store.fetch(store, "openai-codex")
    assert Store.accounts(store) == {:ok, %{}}

    assert :ok = Store.put_account(store, "codex-work", %{"adapter" => "openai-codex"})

    assert path |> File.read!() |> JSON.decode!() == %{
             "version" => 2,
             "providers" => %{"openai-codex" => %{"token" => "v1"}},
             "accounts" => %{"codex-work" => %{"adapter" => "openai-codex"}}
           }
  end

  test "accounts persist beside credentials and survive a restart", %{path: path} do
    store = start_store(path)

    assert :ok = Store.put(store, "codex-work", %{"token" => "work"})
    assert :ok = Store.put_account(store, "codex-work", %{"adapter" => "openai-codex"})
    assert :ok = Store.put_account(store, "codex-home", %{"adapter" => "openai-codex"})

    # Only the known keys are kept.
    assert :ok =
             Store.put_account(store, "cloud2", %{
               "adapter" => "ollama",
               "base" => "ollama-cloud",
               "extra" => true
             })

    assert :ok = Store.delete_account(store, "codex-home")
    assert :ok = Store.delete_account(store, "never-recorded")

    for {id, account} <- [
          {"Bad Name", %{"adapter" => "openai-codex"}},
          {"codex-x", %{"adapter" => ""}},
          {"codex-x", %{"adapter" => "openai-codex", "base" => "Bad Base"}},
          {"codex-x", "openai-codex"}
        ] do
      assert {:error, {:invalid_account, ^id}} = Store.put_account(store, id, account)
    end

    assert :ok = stop_supervised(Store)
    store = start_store(path)

    accounts = %{
      "codex-work" => %{"adapter" => "openai-codex"},
      "cloud2" => %{"adapter" => "ollama", "base" => "ollama-cloud"}
    }

    assert Store.accounts(store) == {:ok, accounts}
    assert {:ok, %{"token" => "work"}} = Store.fetch(store, "codex-work")

    # Deleting credentials keeps the account; the two are managed separately.
    assert :ok = Store.delete(store, "codex-work")
    assert Store.accounts(store) == {:ok, accounts}
  end

  test "malformed accounts are rejected without overwriting the file", %{
    home: home,
    path: path
  } do
    File.mkdir_p!(home)

    for accounts <- [
          [],
          %{"codex-work" => "openai-codex"},
          %{"Bad Id" => %{"adapter" => "a"}},
          %{"codex-work" => %{"adapter" => "a", "base" => 1}}
        ] do
      contents = JSON.encode!(%{"version" => 2, "providers" => %{}, "accounts" => accounts})
      File.write!(path, contents)

      assert {:error, {:invalid_auth_file, ^path, :invalid_accounts}} = start_store_error(path)
      assert File.read!(path) == contents
    end
  end

  test "directory and file permissions are restricted", %{home: home, path: path} do
    store = start_store(path)
    assert :ok = Store.put(store, "openai-codex", %{"token" => "secret"})

    assert (File.stat!(home).mode &&& 0o777) == 0o700
    assert (File.stat!(path).mode &&& 0o777) == 0o600
  end

  test "repairs unsafe permissions before reading an existing file", %{home: home, path: path} do
    File.mkdir_p!(home)
    File.chmod!(home, 0o755)

    File.write!(
      path,
      JSON.encode!(%{
        "version" => 1,
        "providers" => %{"openai-codex" => %{"token" => "secret"}}
      })
    )

    File.chmod!(path, 0o644)
    store = start_store(path)

    assert {:ok, %{"token" => "secret"}} = Store.fetch(store, "openai-codex")
    assert (File.stat!(home).mode &&& 0o777) == 0o700
    assert (File.stat!(path).mode &&& 0o777) == 0o600
  end

  test "reloads persisted credentials after a store restart", %{path: path} do
    store = start_store(path)
    assert :ok = Store.put(store, "openai-codex", %{"token" => "persisted"})
    assert :ok = stop_supervised(Store)

    reloaded_store = start_store(path)
    assert {:ok, %{"token" => "persisted"}} = Store.fetch(reloaded_store, "openai-codex")
  end

  test "a file replaced by a directory fails reads and changes without touching it", %{
    path: path
  } do
    store = start_store(path)
    original = %{"token" => "original"}
    assert :ok = Store.put(store, "openai-codex", original)

    backup = path <> ".backup"
    File.rename!(path, backup)
    File.mkdir!(path)
    marker = Path.join(path, "marker")
    File.write!(marker, "keep")

    assert {:error, {:unsafe_auth_file, ^path, :not_regular}} =
             Store.put(store, "openai-codex", %{"token" => "replacement"})

    assert {:error, {:unsafe_auth_file, ^path, :not_regular}} =
             Store.fetch(store, "openai-codex")

    assert File.read!(marker) == "keep"

    File.rm_rf!(path)
    File.rename!(backup, path)
    assert {:ok, ^original} = Store.fetch(store, "openai-codex")
  end

  # Several VMs share auth.json. Each change must start from the file's
  # current contents, and reads must not serve contents another VM replaced.
  test "stores sharing a file see and keep each other's changes", %{path: path} do
    first = start_store(path, :first)
    second = start_store(path, :second)

    assert :ok = Store.put(first, "openai-codex", %{"refresh_token" => "first"})
    assert :ok = Store.put(second, "anthropic", %{"api_key" => "second"})
    assert :ok = Store.put_account(second, "codex-work", %{"adapter" => "openai-codex"})

    assert {:ok, %{"api_key" => "second"}} = Store.fetch(first, "anthropic")
    assert :stored = Store.status(first, "anthropic")
    assert {:ok, %{"codex-work" => %{"adapter" => "openai-codex"}}} = Store.accounts(first)

    # A rotated token written by one store is what the other reads next.
    assert :ok = Store.put(second, "openai-codex", %{"refresh_token" => "rotated"})
    assert {:ok, %{"refresh_token" => "rotated"}} = Store.fetch(first, "openai-codex")

    assert :ok = Store.delete(first, "anthropic")
    assert :error = Store.fetch(second, "anthropic")

    assert path |> File.read!() |> JSON.decode!() == %{
             "version" => 2,
             "providers" => %{"openai-codex" => %{"refresh_token" => "rotated"}},
             "accounts" => %{"codex-work" => %{"adapter" => "openai-codex"}}
           }
  end

  test "a file another VM replaced after the last read is read again", %{path: path} do
    store = start_store(path)
    assert :ok = Store.put(store, "openai-codex", %{"token" => "old"})
    assert {:ok, %{"token" => "old"}} = Store.fetch(store, "openai-codex")

    # Written like another VM's store would: a new file renamed over the old.
    replacement = path <> ".other"

    File.write!(
      replacement,
      JSON.encode!(%{"version" => 2, "providers" => %{"openai-codex" => %{"token" => "new"}}})
    )

    File.rename!(replacement, path)
    assert {:ok, %{"token" => "new"}} = Store.fetch(store, "openai-codex")
    assert Store.accounts(store) == {:ok, %{}}
  end

  test "a file made invalid while the store runs is reported and never overwritten", %{
    path: path
  } do
    store = start_store(path)
    assert :ok = Store.put(store, "openai-codex", %{"token" => "secret"})

    File.write!(path, "{not json")

    assert {:error, {:malformed_auth_file, ^path}} = Store.fetch(store, "openai-codex")
    assert {:error, {:malformed_auth_file, ^path}} = Store.accounts(store)

    assert {:error, {:malformed_auth_file, ^path}} =
             Store.put(store, "anthropic", %{"api_key" => "key"})

    assert File.read!(path) == "{not json"
  end

  test "concurrent writes remain valid and preserve every namespace", %{path: path} do
    store = start_store(path)

    1..40
    |> Task.async_stream(
      fn number ->
        Store.put(store, "provider-#{number}", %{"generation" => number})
      end,
      max_concurrency: 20,
      timeout: 5_000
    )
    |> Enum.each(fn result -> assert {:ok, :ok} = result end)

    envelope = path |> File.read!() |> JSON.decode!()
    assert envelope["version"] == 2
    assert map_size(envelope["providers"]) == 40
    assert envelope["providers"]["provider-17"] == %{"generation" => 17}
  end

  # Two stores on one file stand for two VMs: each change re-reads the file
  # and renames its result over it, and without the write lock a rename
  # landing between another store's re-read and rename dropped that change.
  test "concurrent changes from stores sharing a file lose none", %{path: path} do
    stores = [start_store(path, :first), start_store(path, :second)]

    for(store <- stores, number <- 1..40, do: {store, number})
    |> Task.async_stream(
      fn {store, number} ->
        Store.put(store, "provider-#{inspect(store)}-#{number}", %{"generation" => number})
      end,
      max_concurrency: 80,
      timeout: 15_000
    )
    |> Enum.each(fn result -> assert {:ok, :ok} = result end)

    assert map_size(JSON.decode!(File.read!(path))["providers"]) == 80
  end

  test "a change waits for the write lock and fails when it stays held", %{
    home: home,
    path: path
  } do
    store = start_store(path, Store, write_lock_timeout: 200)
    assert :ok = Store.put(store, "openai-codex", %{"token" => "first"})
    before = File.read!(path)

    {:ok, lock} = FileLock.acquire(Path.join(home, ".auth.json.lock"))

    assert {:error, {:auth_file_locked, ^path}} =
             Store.put(store, "openai-codex", %{"token" => "second"})

    assert {:error, {:auth_file_locked, ^path}} =
             Store.put_account(store, "codex-work", %{"adapter" => "openai-codex"})

    assert File.read!(path) == before

    FileLock.release(lock)
    assert :ok = Store.put(store, "openai-codex", %{"token" => "second"})
    assert {:ok, %{"token" => "second"}} = Store.fetch(store, "openai-codex")
  end

  # A change may wait up to five seconds for the write lock; its call must
  # outlast that wait and return the error instead of exiting the caller.
  @tag timeout: 30_000
  test "a change that waits out the default write lock returns an error", %{
    home: home,
    path: path
  } do
    store = start_store(path)
    File.mkdir_p!(home)
    {:ok, lock} = FileLock.acquire(Path.join(home, ".auth.json.lock"))

    assert {:error, {:auth_file_locked, ^path}} =
             Store.put(store, "openai-codex", %{"token" => "late"})

    FileLock.release(lock)
  end

  test "lock timeouts must be non-negative integers, the write lock's at most 5000", %{
    path: path
  } do
    assert {:error, {:invalid_option, :write_lock_timeout}} =
             start_store_error(path, write_lock_timeout: 5_001)

    assert {:error, {:invalid_option, :credential_lock_timeout}} =
             start_store_error(path, credential_lock_timeout: :infinity)
  end

  describe "with_lock/3" do
    test "runs the function, which can fetch and change credentials", %{
      home: home,
      path: path
    } do
      store = start_store(path)
      assert :ok = Store.put(store, "openai-codex", %{"refresh_token" => "old"})

      assert {:ok, %{"refresh_token" => "new"}} =
               CredentialStore.with_lock({Store, store}, "openai-codex", fn ->
                 {:ok, %{"refresh_token" => "old"}} = Store.fetch(store, "openai-codex")
                 :ok = Store.put(store, "openai-codex", %{"refresh_token" => "new"})
                 Store.fetch(store, "openai-codex")
               end)

      # The lock files are private, beside auth.json, and never name the
      # namespace.
      lock_files = home |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".lock"))
      assert ".auth.json.lock" in lock_files
      assert [_write_lock, _namespace_lock] = lock_files
      refute Enum.any?(lock_files, &(&1 =~ "codex"))

      for file <- lock_files do
        assert (File.stat!(Path.join(home, file)).mode &&& 0o777) == 0o600
      end
    end

    test "serializes holders of one namespace across stores sharing a file", %{path: path} do
      first = start_store(path, :first)
      second = start_store(path, :second)

      holder = start_lock_holder(first, "openai-codex")
      assert_receive {:holding, ^holder}, 5_000

      waiter = start_lock_holder(second, "openai-codex")
      refute_receive {:holding, ^waiter}, 300

      # Another namespace does not wait.
      assert :other = Store.with_lock(second, "anthropic", fn -> :other end)

      release_lock_holder(holder)
      assert_receive {:holding, ^waiter}, 5_000
      release_lock_holder(waiter)
    end

    test "a function that raises or throws releases the lock", %{path: path} do
      store = start_store(path, Store, credential_lock_timeout: 1_000)

      assert_raise RuntimeError, fn ->
        Store.with_lock(store, "openai-codex", fn -> raise "refresh failed" end)
      end

      assert catch_throw(Store.with_lock(store, "openai-codex", fn -> throw(:stop) end)) ==
               :stop

      assert :again = Store.with_lock(store, "openai-codex", fn -> :again end)
    end

    test "a holder that dies releases the lock", %{path: path} do
      first = start_store(path, :first)
      second = start_store(path, :second)

      holder = start_lock_holder(first, "openai-codex")
      assert_receive {:holding, ^holder}, 5_000
      Process.exit(holder, :kill)

      assert :after = Store.with_lock(second, "openai-codex", fn -> :after end)
    end

    test "gives up after the configured wait", %{path: path} do
      store = start_store(path, Store, credential_lock_timeout: 200)

      holder = start_lock_holder(store, "openai-codex")
      assert_receive {:holding, ^holder}, 5_000

      assert {:error, {:credential_lock_failed, {:lock_timeout, lock_path}}} =
               Store.with_lock(store, "openai-codex", fn -> flunk("ran unlocked") end)

      assert Path.dirname(lock_path) == Path.dirname(path)
      release_lock_holder(holder)
    end

    test "rejects an invalid namespace", %{path: path} do
      store = start_store(path)

      assert {:error, {:credential_lock_failed, :invalid_credential_namespace}} =
               Store.with_lock(store, "", fn -> flunk("ran unlocked") end)
    end

    test "reports a store that is not running as a lock failure", %{path: path} do
      store = start_store(path)
      stop_supervised!(Store)

      assert {:error, {:credential_lock_failed, {:store_unavailable, _reason}}} =
               Store.with_lock(store, "openai-codex", fn -> flunk("ran unlocked") end)
    end
  end

  # The temporary file was named after a counter that restarts with every VM,
  # so a file a killed VM left behind made a later VM's saves fail.
  test "a leftover temporary file from another VM does not break saving", %{
    home: home,
    path: path
  } do
    File.mkdir_p!(home)
    next = System.unique_integer([:positive, :monotonic])

    for number <- next..(next + 5_000) do
      File.write!(Path.join(home, ".auth.json.tmp-#{number}"), "")
    end

    store = start_store(path)
    assert :ok = Store.put(store, "openai-codex", %{"token" => "fresh"})
    assert {:ok, %{"token" => "fresh"}} = Store.fetch(store, "openai-codex")
  end

  test "credential validation errors do not expose values", %{path: path} do
    store = start_store(path)
    token = "highly-sensitive-token"
    result = Store.put(store, "openai-codex", %{"access_token" => token, "bad" => self()})

    assert {:error, :invalid_credentials} = result
    refute inspect(result) =~ token
    refute File.exists?(path)
  end

  test "status and crash reports show no credentials", %{path: path} do
    store = start_store(path)
    secret = "do-not-log-#{System.unique_integer([:positive])}"
    assert :ok = Store.put(store, "openai-codex", %{"access_token" => secret})

    status = :sys.get_status(store)
    refute inspect(status, limit: :infinity, printable_limit: :infinity) =~ secret

    crash = %{
      state: :sys.get_state(store),
      message: {:"$gen_call", {self(), make_ref()}, {:put, "other", %{"token" => secret}}},
      reason: :boom,
      log: [{:in, {:"$gen_call", {self(), make_ref()}, {:put, "x", %{"token" => secret}}}}]
    }

    redacted = Store.format_status(crash)
    refute inspect(redacted, limit: :infinity, printable_limit: :infinity) =~ secret
    assert redacted.state.providers == %{"openai-codex" => :redacted}
    assert {:"$gen_call", _from, :put} = redacted.message
  end

  test "rejects an auth file symlink", %{home: home, path: path} do
    File.mkdir_p!(home)
    target = Path.join(home, "target.json")
    File.write!(target, JSON.encode!(%{"version" => 1, "providers" => %{}}))
    File.ln_s!(target, path)

    assert {:error, {:unsafe_auth_file, ^path, :symlink}} = start_store_error(path)
  end

  defp start_store(path, id \\ Store, opts \\ []) do
    start_supervised!(Supervisor.child_spec({Store, [path: path, name: nil] ++ opts}, id: id))
  end

  defp start_store_error(path, opts \\ []) do
    Process.flag(:trap_exit, true)
    Store.start_link([path: path] ++ opts)
  end

  # Holds the namespace lock in a separate process until told to release it.
  defp start_lock_holder(store, namespace) do
    test = self()

    spawn(fn ->
      Store.with_lock(store, namespace, fn ->
        send(test, {:holding, self()})

        receive do
          :release -> :ok
        end
      end)

      send(test, {:released, self()})
    end)
  end

  defp release_lock_holder(holder) do
    send(holder, :release)
    assert_receive {:released, ^holder}, 5_000
  end
end

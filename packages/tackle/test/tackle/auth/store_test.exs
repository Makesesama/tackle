defmodule Tackle.Auth.StoreTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Tackle.Auth.Store
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

    assert {:error, {:unsupported_auth_version, ^path, 2}} = start_store_error(path)
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
    assert Store.accounts(store) == %{}

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

    assert Store.accounts(store) == accounts
    assert {:ok, %{"token" => "work"}} = Store.fetch(store, "codex-work")

    # Deleting credentials keeps the account; the two are managed separately.
    assert :ok = Store.delete(store, "codex-work")
    assert Store.accounts(store) == accounts
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

  test "a failed replacement leaves memory and existing disk data unchanged", %{path: path} do
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

    assert {:ok, ^original} = Store.fetch(store, "openai-codex")

    assert File.read!(backup) |> JSON.decode!() == %{
             "version" => 2,
             "providers" => %{"openai-codex" => original},
             "accounts" => %{}
           }

    assert File.read!(marker) == "keep"
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

  test "credential validation errors do not expose values", %{path: path} do
    store = start_store(path)
    token = "highly-sensitive-token"
    result = Store.put(store, "openai-codex", %{"access_token" => token, "bad" => self()})

    assert {:error, :invalid_credentials} = result
    refute inspect(result) =~ token
    refute File.exists?(path)
  end

  test "rejects an auth file symlink", %{home: home, path: path} do
    File.mkdir_p!(home)
    target = Path.join(home, "target.json")
    File.write!(target, JSON.encode!(%{"version" => 1, "providers" => %{}}))
    File.ln_s!(target, path)

    assert {:error, {:unsafe_auth_file, ^path, :symlink}} = start_store_error(path)
  end

  defp start_store(path) do
    start_supervised!({Store, path: path, name: nil})
  end

  defp start_store_error(path) do
    Process.flag(:trap_exit, true)
    Store.start_link(path: path)
  end
end

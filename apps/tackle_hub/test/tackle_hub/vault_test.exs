defmodule Tackle.Hub.VaultTest do
  use ExUnit.Case, async: true

  alias Tackle.Hub.Vault

  @key_a Base.encode64(:binary.copy(<<1>>, 32))
  @key_b Base.encode64(:binary.copy(<<2>>, 32))

  describe "ciphers/2" do
    test "uses AES-GCM, the current key first" do
      assert {:ok, [current: {Cloak.Ciphers.AES.GCM, current}, retired_1: {_cipher, retired}]} =
               Vault.ciphers(@key_b, [@key_a])

      assert current[:key] == Base.decode64!(@key_b)
      assert retired[:key] == Base.decode64!(@key_a)
      assert current[:tag] != retired[:tag]
    end

    test "tags name the key, not its position" do
      {:ok, [current: {_, alone}]} = Vault.ciphers(@key_a, [])
      {:ok, [_current, retired_1: {_, retired}]} = Vault.ciphers(@key_b, [@key_a])

      assert alone[:tag] == retired[:tag]
    end

    test "rejects missing, malformed, short, and duplicate keys" do
      assert {:error, "the current key is not set"} = Vault.ciphers(nil, [])
      assert {:error, "the current key is not valid base64"} = Vault.ciphers("not base64!", [])

      assert {:error, "the current key is not 32 bytes"} =
               Vault.ciphers(Base.encode64("short"), [])

      assert {:error, "retired key 2 is not valid base64"} =
               Vault.ciphers(@key_a, [@key_b, "%%%"])

      assert {:error, "a key is configured more than once"} = Vault.ciphers(@key_a, [@key_a])
    end
  end

  test "values written before a rotation decrypt after it" do
    {:ok, before} = Vault.ciphers(@key_a, [])
    {:ok, rotated} = Vault.ciphers(@key_b, [@key_a])

    old = Cloak.Vault.encrypt!([ciphers: before], "secret")
    new = Cloak.Vault.encrypt!([ciphers: rotated], "secret")

    assert Cloak.Vault.decrypt!([ciphers: rotated], old) == "secret"
    assert Cloak.Vault.decrypt!([ciphers: rotated], new) == "secret"
    # The new key encrypts; without it, new values cannot be read.
    assert {:error, _reason} = Cloak.Vault.decrypt([ciphers: before], new)
  end

  test "an invalid key stops the vault instead of starting it" do
    assert {:stop, {:invalid_cloak_configuration, "the current key is not set"}} =
             Vault.init(json_library: JSON)
  end

  test "the running vault round-trips with an authenticated cipher" do
    ciphertext = Vault.encrypt!("secret")

    assert Vault.decrypt!(ciphertext) == "secret"

    last = :binary.last(ciphertext)
    tampered = binary_part(ciphertext, 0, byte_size(ciphertext) - 1) <> <<Bitwise.bxor(last, 1)>>

    assert {:error, %Vault.DecryptionError{}} = Vault.decrypt(tampered)
    assert_raise Vault.DecryptionError, fn -> Vault.decrypt!(tampered) end
  end
end

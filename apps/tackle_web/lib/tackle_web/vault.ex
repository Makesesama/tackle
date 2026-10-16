defmodule Tackle.Web.Vault do
  @moduledoc """
  The Cloak vault that encrypts secrets stored in the database (forge
  integration secrets and provider credentials, through AshCloak).

  Every key is a base64-encoded 32-byte AES key used with
  `Cloak.Ciphers.AES.GCM`, which authenticates its ciphertext. (Cloak's
  AES-CTR cipher does not, and must not be used.) Configuration, under
  `config :tackle_web, Tackle.Web.Vault`:

    * `:key` - the current key; new values are encrypted with it. In
      production it comes from `TACKLE_WEB_CLOAK_KEY`.
    * `:retired_keys` - earlier keys, still accepted for decryption so
      values written before a rotation stay readable. In production a
      comma-separated `TACKLE_WEB_CLOAK_RETIRED_KEYS`.

  Each ciphertext starts with a tag derived from its key's fingerprint, so
  the vault picks the right key for decryption regardless of the order of
  the configured keys. To rotate: add the new key as `:key`, move the old
  one to `:retired_keys`, re-encrypt the stored values, then drop it.

  An invalid key stops the vault, and with it the application, instead of
  starting without encryption.

  A ciphertext that fails authentication (tampered with, or written with
  another key under the same tag) is an error from `decrypt/1` and raises
  from `decrypt!/1`. Cloak 1.1 itself returns `{:ok, :error}` for it.
  """

  use Cloak.Vault, otp_app: :tackle_web

  @key_bytes 32

  defmodule DecryptionError do
    @moduledoc "A ciphertext that failed authentication."
    defexception message: "ciphertext failed authentication"
  end

  @impl Cloak.Vault
  def decrypt(ciphertext) do
    with {:ok, config} <- Cloak.Vault.read_config(@table_name) do
      authenticated(Cloak.Vault.decrypt(config, ciphertext))
    end
  end

  @impl Cloak.Vault
  def decrypt!(ciphertext) do
    case decrypt(ciphertext) do
      {:ok, plaintext} -> plaintext
      {:error, error} -> raise error
    end
  end

  # AES-GCM returns `:error` as the "plaintext" when the tag does not match,
  # and Cloak wraps it as a success. A plaintext is always a binary.
  defp authenticated({:ok, plaintext}) when is_binary(plaintext), do: {:ok, plaintext}
  defp authenticated({:ok, _not_plaintext}), do: {:error, %DecryptionError{}}
  defp authenticated({:error, error}), do: {:error, error}

  @impl GenServer
  def init(config) do
    case ciphers(Keyword.get(config, :key), Keyword.get(config, :retired_keys, [])) do
      {:ok, ciphers} ->
        {:ok, config |> Keyword.drop([:key, :retired_keys]) |> Keyword.put(:ciphers, ciphers)}

      {:error, message} ->
        {:stop, {:invalid_cloak_configuration, message}}
    end
  end

  @doc """
  Builds the vault's ciphers from the current key and the retired keys
  (base64 strings). The current key comes first, so it is the one Cloak
  encrypts with.
  """
  @spec ciphers(String.t() | nil, [String.t()]) :: {:ok, keyword()} | {:error, String.t()}
  def ciphers(key, retired_keys) when is_list(retired_keys) do
    with {:ok, current} <- decode_key(key, "the current key"),
         {:ok, retired} <- decode_retired(retired_keys),
         :ok <- distinct([current | retired]) do
      {:ok,
       Enum.with_index([current | retired], fn key, index ->
         {cipher_name(index), {Cloak.Ciphers.AES.GCM, tag: tag(key), key: key, iv_length: 12}}
       end)}
    end
  end

  def ciphers(_key, _retired_keys), do: {:error, "retired keys must be a list"}

  defp decode_retired(keys) do
    keys
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {key, position}, {:ok, acc} ->
      case decode_key(key, "retired key #{position}") do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_key(nil, name), do: {:error, "#{name} is not set"}

  defp decode_key(key, name) when is_binary(key) do
    case Base.decode64(String.trim(key)) do
      {:ok, <<_::binary-size(@key_bytes)>> = decoded} -> {:ok, decoded}
      {:ok, _other} -> {:error, "#{name} is not #{@key_bytes} bytes"}
      :error -> {:error, "#{name} is not valid base64"}
    end
  end

  defp decode_key(_key, name), do: {:error, "#{name} is not a string"}

  defp distinct(keys) do
    if length(Enum.uniq(keys)) == length(keys),
      do: :ok,
      else: {:error, "a key is configured more than once"}
  end

  # The tag is stored in front of every ciphertext. It names the key without
  # revealing it: the first 8 bytes of its SHA-256 digest.
  defp tag(key) do
    "AES.GCM." <> Base.encode16(binary_part(:crypto.hash(:sha256, key), 0, 8), case: :lower)
  end

  defp cipher_name(0), do: :current
  defp cipher_name(index), do: :"retired_#{index}"
end

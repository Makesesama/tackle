defmodule Tackle.Plugins.Anthropic.PKCE do
  @moduledoc false

  @type codes :: %{verifier: String.t(), challenge: String.t()}

  @doc """
  Generates a PKCE verifier and its S256 challenge.

  The verifier is 32 random bytes encoded with unpadded base64url, producing the
  43-character form required by RFC 7636.
  """
  @spec generate() :: codes()
  def generate do
    verifier = 32 |> :crypto.strong_rand_bytes() |> base64url()
    challenge = :sha256 |> :crypto.hash(verifier) |> base64url()

    %{verifier: verifier, challenge: challenge}
  end

  defp base64url(value), do: Base.url_encode64(value, padding: false)
end

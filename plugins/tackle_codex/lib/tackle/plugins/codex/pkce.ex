defmodule Tackle.Plugins.Codex.PKCE do
  @moduledoc false

  @type codes :: %{verifier: String.t(), challenge: String.t()}

  @spec generate() :: codes()
  def generate do
    verifier = 64 |> :crypto.strong_rand_bytes() |> base64url()
    challenge = :sha256 |> :crypto.hash(verifier) |> base64url()

    %{verifier: verifier, challenge: challenge}
  end

  defp base64url(value), do: Base.url_encode64(value, padding: false)
end

defmodule Tackle.CLI.SecretInput do
  @moduledoc false

  @spec read(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def read(prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    reader = Keyword.get(opts, :reader, &read_password/1)

    prompt
    |> String.to_charlist()
    |> reader.()
    |> normalize()
  end

  defp read_password(prompt) do
    IO.write(prompt)

    case :io.get_password() do
      {:error, :enotsup} -> read_visible_fallback()
      result -> result
    end
  end

  defp read_visible_fallback do
    IO.puts(:stderr, "\nwarning: hidden input is unavailable; the API key may be visible")
    IO.gets("") || :eof
  end

  defp normalize(password) when is_binary(password), do: validate(password)

  defp normalize(password) when is_list(password) do
    case :unicode.characters_to_binary(password) do
      value when is_binary(value) -> validate(value)
      _invalid -> {:error, :invalid_secret_input}
    end
  end

  defp normalize(:eof), do: {:error, :secret_input_eof}
  defp normalize({:error, reason}), do: {:error, {:secret_input_failed, reason}}
  defp normalize(_value), do: {:error, :invalid_secret_input}

  defp validate(value) do
    case String.trim(value) do
      "" -> {:error, :empty_api_key}
      api_key -> {:ok, api_key}
    end
  end
end

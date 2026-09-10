defmodule Tackle.CLI.SecretInputTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.SecretInput

  test "reads and trims a hidden secret" do
    reader = fn prompt ->
      send(self(), {:prompt, prompt})
      ~c"  ds-test-key  "
    end

    assert {:ok, "ds-test-key"} = SecretInput.read("DeepSeek API key: ", reader: reader)
    assert_receive {:prompt, ~c"DeepSeek API key: "}
  end

  test "rejects empty, unavailable, and failed input" do
    assert {:error, :empty_api_key} = SecretInput.read("key: ", reader: fn _ -> ~c"  " end)
    assert {:error, :secret_input_eof} = SecretInput.read("key: ", reader: fn _ -> :eof end)

    assert {:error, {:secret_input_failed, :enotsup}} =
             SecretInput.read("key: ", reader: fn _ -> {:error, :enotsup} end)

    assert {:error, :invalid_secret_input} =
             SecretInput.read("key: ", reader: fn _ -> :unexpected end)
  end
end

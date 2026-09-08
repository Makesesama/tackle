defmodule Tackle.CLI.ParserTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.Parser

  test "parses the default run command with only a model override" do
    assert {:ok, {:run, %{model: "openai-codex/gpt-5.6-sol", thinking: nil, prompt: nil}}} =
             Parser.parse(["--model", "openai-codex/gpt-5.6-sol"])
  end

  test "parses run prompt without exposing adapter module selection" do
    assert {:ok, {:run, %{model: "openai-codex/gpt-5.6-sol", thinking: "high", prompt: "hello"}}} =
             Parser.parse([
               "run",
               "--model",
               "openai-codex/gpt-5.6-sol",
               "--thinking",
               "high",
               "hello"
             ])
  end

  test "parses model listing command" do
    assert {:ok, {:models, %{}}} = Parser.parse(["models"])
  end

  test "parses auth commands" do
    assert {:ok, {:auth_login, %{provider: "openai-codex"}}} =
             Parser.parse(["auth", "login", "openai-codex"])

    assert {:ok, {:auth_status, %{provider: nil}}} = Parser.parse(["auth", "status"])

    assert {:ok, {:auth_logout, %{provider: "openai-codex"}}} =
             Parser.parse(["auth", "logout", "openai-codex"])
  end

  test "does not expose adapter module selection" do
    assert {:error, error} = Parser.parse(["run", "--adapter", "Some.Module"])
    assert error =~ "unrecognized arguments"

    assert {:help, help} = Parser.parse(["--help"])
    assert help =~ "--model"
    assert help =~ "--thinking"
    refute help =~ "--adapter"
  end
end

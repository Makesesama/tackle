defmodule Tackle.CLI.ParserTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.Parser

  test "parses the default run command with only a model override" do
    assert {:ok,
            {:run,
             %{
               model: "openai-codex/gpt-5.6-sol",
               thinking: nil,
               prompt: nil,
               resume: nil,
               abandon: false
             }}} = Parser.parse(["--model", "openai-codex/gpt-5.6-sol"])
  end

  test "parses run prompt without exposing adapter module selection" do
    assert {:ok,
            {:run,
             %{
               model: "openai-codex/gpt-5.6-sol",
               thinking: "high",
               prompt: "hello",
               resume: nil,
               abandon: false
             }}} =
             Parser.parse([
               "run",
               "--model",
               "openai-codex/gpt-5.6-sol",
               "--thinking",
               "high",
               "hello"
             ])
  end

  test "parses durable session resume and recovery options" do
    assert {:ok, {:run, run}} =
             Parser.parse(["run", "--resume", "session-1", "--abandon", "hello"])

    assert run.resume == "session-1"
    assert run.abandon == true
    assert run.prompt == "hello"
  end

  test "parses session listing and search command" do
    assert {:ok, {:sessions, %{query: nil, limit: nil}}} = Parser.parse(["sessions"])

    assert {:ok, {:sessions, %{query: "hello", limit: 5}}} =
             Parser.parse(["sessions", "--query", "hello", "--limit", "5"])
  end

  test "parses model listing command" do
    assert {:ok, {:models, %{}}} = Parser.parse(["models"])
  end

  test "shows auth help when no auth subcommand is given" do
    assert {:help, help} = Parser.parse(["auth"])
    assert help =~ "Manage provider credentials"
    assert help =~ "login"
    assert help =~ "status"
    assert help =~ "usage"
    assert help =~ "logout"
  end

  test "parses auth commands" do
    assert {:ok, {:auth_login, %{provider: "openai-codex"}}} =
             Parser.parse(["auth", "login", "openai-codex"])

    assert {:ok, {:auth_status, %{provider: nil}}} = Parser.parse(["auth", "status"])

    assert {:ok, {:auth_usage, %{provider: nil}}} = Parser.parse(["auth", "usage"])

    assert {:ok, {:auth_usage, %{provider: "deepseek"}}} =
             Parser.parse(["auth", "usage", "deepseek"])

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

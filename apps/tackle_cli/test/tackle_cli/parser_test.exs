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

  test "parses a valueless resume as the most recent session" do
    assert {:ok, {:run, %{resume: :latest, prompt: nil}}} = Parser.parse(["--resume"])
    assert {:ok, {:run, %{resume: :latest, prompt: nil}}} = Parser.parse(["run", "--resume"])

    assert {:ok, {:run, %{resume: :latest, model: "deepseek/deepseek-chat"}}} =
             Parser.parse(["--resume", "--model", "deepseek/deepseek-chat"])

    assert {:ok, {:run, %{resume: :latest, abandon: true}}} =
             Parser.parse(["run", "--resume", "--abandon"])
  end

  test "keeps an explicit session id and an id after a double dash" do
    assert {:ok, {:run, %{resume: "session-1", prompt: "hello"}}} =
             Parser.parse(["run", "--resume=session-1", "hello"])

    assert {:ok, {:run, %{resume: "session-1", prompt: "hello"}}} =
             Parser.parse(["run", "--resume", "session-1", "hello"])

    assert {:ok, {:run, %{resume: nil, prompt: "--resume"}}} =
             Parser.parse(["run", "--", "--resume"])
  end

  test "parses session listing and search command" do
    assert {:ok,
            {:sessions, %{query: nil, limit: nil, cursor: nil, format: :human, color: :auto}}} =
             Parser.parse(["sessions"])

    assert {:ok,
            {:sessions,
             %{
               query: "hello",
               limit: 5,
               cursor: "next-page",
               format: :json,
               color: :never
             }}} =
             Parser.parse([
               "sessions",
               "--query",
               "hello",
               "--limit",
               "5",
               "--cursor",
               "next-page",
               "--format",
               "json",
               "--color",
               "never"
             ])
  end

  test "rejects unsupported session output options" do
    assert {:error, error} = Parser.parse(["sessions", "--format", "yaml"])
    assert error =~ "must be human, plain, or json"

    assert {:error, error} = Parser.parse(["sessions", "--color", "sometimes"])
    assert error =~ "must be auto, always, or never"
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
    assert {:ok, {:auth_login, %{provider: "openai-codex", format: :human, color: :auto}}} =
             Parser.parse(["auth", "login", "openai-codex"])

    assert {:ok, {:auth_status, %{provider: nil, format: :human, color: :auto}}} =
             Parser.parse(["auth", "status"])

    assert {:ok, {:auth_usage, %{provider: nil, format: :human, color: :auto}}} =
             Parser.parse(["auth", "usage"])

    assert {:ok, {:auth_usage, %{provider: "deepseek", format: :json, color: :never}}} =
             Parser.parse([
               "auth",
               "usage",
               "deepseek",
               "--format",
               "json",
               "--color",
               "never"
             ])

    assert {:ok, {:auth_logout, %{provider: "openai-codex", format: :plain, color: :auto}}} =
             Parser.parse(["auth", "logout", "openai-codex", "--format", "plain"])
  end

  test "rejects unsupported auth output options" do
    assert {:error, error} = Parser.parse(["auth", "status", "--format", "yaml"])
    assert error =~ "must be human, plain, or json"

    assert {:error, error} = Parser.parse(["auth", "usage", "--color", "sometimes"])
    assert error =~ "must be auto, always, or never"
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

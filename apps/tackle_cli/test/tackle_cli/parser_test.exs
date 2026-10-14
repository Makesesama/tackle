defmodule Tackle.CLI.ParserTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.Parser

  test "parses the sdk subcommand" do
    assert {:ok, {:sdk, %{}}} = Parser.parse(["sdk"])
  end

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

  test "parses the review command with its defaults" do
    assert {:ok,
            {:review,
             %{
               range: nil,
               staged: false,
               profile: nil,
               samples: 1,
               format: :text,
               model: nil,
               thinking: nil
             }}} = Parser.parse(["review"])
  end

  test "parses review range, profile, samples, format, and the global model options" do
    assert {:ok,
            {:review,
             %{
               range: "main..HEAD",
               staged: false,
               profile: :quiet,
               samples: 3,
               format: :json,
               model: "openai-codex/gpt-5.6-sol",
               thinking: "high"
             }}} =
             Parser.parse([
               "review",
               "main..HEAD",
               "--profile",
               "quiet",
               "--samples",
               "3",
               "--format",
               "json",
               "--model",
               "openai-codex/gpt-5.6-sol",
               "--thinking",
               "high"
             ])

    assert {:ok, {:review, %{profile: :assertive}}} =
             Parser.parse(["review", "--profile", "assertive"])

    assert {:ok, {:review, %{staged: true, range: nil}}} = Parser.parse(["review", "--staged"])
  end

  test "parses review cost settings into tuning options" do
    assert {:ok, {:review, %{tuning: []}}} = Parser.parse(["review"])

    assert {:ok,
            {:review,
             %{
               tuning: [
                 units: [max_changed_lines: 300, pack_files: false],
                 verify_batch: 2,
                 verify_limit: 8,
                 score_batch: 5,
                 thinking: [detector: "medium", scorer: "off"]
               ]
             }}} =
             Parser.parse([
               "review",
               "--unit-lines",
               "300",
               "--no-pack-files",
               "--verify-batch",
               "2",
               "--verify-limit",
               "8",
               "--score-batch",
               "5",
               "--stage-thinking",
               "detector=medium, scorer=off"
             ])

    assert {:ok, {:review, %{tuning: [units: [pack_files: false]]}}} =
             Parser.parse(["review", "--no-pack-files"])

    for value <- ["writer=low", "detector=huge", "detector", ","] do
      assert {:error, _message} = Parser.parse(["review", "--stage-thinking", value])
    end

    assert {:error, _message} = Parser.parse(["review", "--unit-lines", "0"])
  end

  test "rejects --staged together with a review range" do
    assert {:error, error} = Parser.parse(["review", "--staged", "HEAD~1"])
    assert error =~ "--staged cannot be combined with a RANGE"
  end

  test "rejects invalid review options" do
    assert {:error, error} = Parser.parse(["review", "--profile", "loud"])
    assert error =~ "must be quiet, default, or assertive"

    for samples <- ["0", "-1", "two", "1.5"] do
      assert {:error, error} = Parser.parse(["review", "--samples", samples])
      assert error =~ "must be a positive integer"
    end

    assert {:error, error} = Parser.parse(["review", "--format", "human"])
    assert error =~ "must be text or json"

    assert {:error, _error} = Parser.parse(["review", "a..b", "extra"])
  end

  test "review --help and -h show the review help instead of naming a revision" do
    for flag <- ["--help", "-h"] do
      assert {:help, help} = Parser.parse(["review", flag])
      assert help =~ "RANGE"
      assert help =~ "--staged"
    end
  end

  test "rejects a review range that looks like an option" do
    assert {:error, error} = Parser.parse(["review", "--verbose"])
    assert error =~ ~s(unrecognized argument: "--verbose")
    assert error =~ "tackle help review"
  end

  test "documents the review command and its exit status" do
    assert {:help, help} = Parser.parse(["help", "review"])
    assert help =~ "Exits 1 when blocking findings are shown"
    assert help =~ "--staged"
    assert help =~ "--profile"
    assert help =~ "--samples"
    assert help =~ "--format"
    assert help =~ "RANGE"
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
    assert {:ok,
            {:auth_login, %{provider: "openai-codex", as: nil, format: :human, color: :auto}}} =
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

  test "parses auth login with a named account" do
    assert {:ok, {:auth_login, %{provider: "openai-codex", as: "codex-work"}}} =
             Parser.parse(["auth", "login", "openai-codex", "--as", "codex-work"])

    assert {:ok, {:auth_login, %{provider: "openai-codex", as: "codex-work"}}} =
             Parser.parse(["auth", "login", "--as", "codex-work", "openai-codex"])

    assert {:error, error} = Parser.parse(["auth", "login", "openai-codex", "--as"])
    assert error =~ "--as"

    assert {:error, _error} = Parser.parse(["auth", "status", "--as", "codex-work"])

    assert {:help, help} = Parser.parse(["help", "auth", "login"])
    assert help =~ "--as"
  end

  test "rejects unsupported auth output options" do
    assert {:error, error} = Parser.parse(["auth", "status", "--format", "yaml"])
    assert error =~ "must be human, plain, or json"

    assert {:error, error} = Parser.parse(["auth", "usage", "--color", "sometimes"])
    assert error =~ "must be auto, always, or never"
  end

  test "parses MCP connection and OAuth commands" do
    assert {:help, help} = Parser.parse(["mcp"])
    assert help =~ "Manage MCP servers"
    assert {:ok, {:mcp_list, %{}}} = Parser.parse(["mcp", "list"])

    assert {:ok,
            {:mcp_add, %{name: "docs", http: "https://mcp.example/mcp", stdio: nil, args: []}}} =
             Parser.parse(["mcp", "add", "docs", "--http", "https://mcp.example/mcp"])

    assert {:ok, {:mcp_add, %{name: "local", stdio: "npx", args: ["-y", "server"]}}} =
             Parser.parse([
               "mcp",
               "add",
               "local",
               "--stdio",
               "npx",
               "--arg",
               "-y",
               "--arg",
               "server"
             ])

    assert {:ok, {:mcp_remove, "docs"}} = Parser.parse(["mcp", "remove", "docs"])

    assert {:ok, {:mcp_login, %{name: "docs", client_id: nil}}} =
             Parser.parse(["mcp", "auth", "login", "docs"])

    assert {:ok, {:mcp_login, %{name: "docs", client_id: "registered"}}} =
             Parser.parse(["mcp", "auth", "login", "docs", "--client-id", "registered"])

    assert {:ok, {:mcp_status, nil}} = Parser.parse(["mcp", "auth", "status"])
    assert {:ok, {:mcp_logout, "docs"}} = Parser.parse(["mcp", "auth", "logout", "docs"])
  end

  test "does not expose adapter module selection" do
    assert {:error, error} = Parser.parse(["run", "--adapter", "Some.Module"])
    assert error =~ "unrecognized arguments"

    assert {:help, help} = Parser.parse(["--help"])
    assert help =~ "--model"
    assert help =~ "--thinking"
    refute help =~ "--adapter"
  end

  test "parses the canonical max thinking level" do
    assert {:ok, {:run, %{thinking: "max"}}} = Parser.parse(["run", "--thinking", "max"])
  end
end

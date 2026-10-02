defmodule Tackle.Plugins.Anthropic.PromptTest do
  use ExUnit.Case, async: true

  alias Tackle.Plugins.Anthropic.Prompt

  test "builds billing, identity, and cache-controlled host blocks for OAuth" do
    assert [billing, identity, host] =
             Prompt.system_blocks("You are helpful.", nil, true)

    assert billing["type"] == "text"
    assert billing["text"] =~ "x-anthropic-billing-header: cc_version=2.1.280;"
    assert billing["text"] =~ "cc_entrypoint=cli; cch=00000; cc_prompt_id="
    refute Map.has_key?(billing, "cache_control")

    assert identity["text"] == "You are a Claude agent, built on Anthropic's Claude Agent SDK."
    refute Map.has_key?(identity, "cache_control")

    assert host["text"] == "You are helpful."
    assert host["cache_control"] == %{"type" => "ephemeral"}
  end

  test "api-key requests send only the host prompt" do
    assert Prompt.system_blocks("Be terse", nil, false) == [
             %{
               "type" => "text",
               "text" => "Be terse",
               "cache_control" => %{"type" => "ephemeral"}
             }
           ]

    assert Prompt.system_blocks(nil, nil, false) == nil
    assert Prompt.system_blocks(nil, nil, true) |> length() == 2
  end

  test "appends the schema instruction to the host prompt" do
    assert [billing, identity, host] =
             Prompt.system_blocks("Be useful", "Return JSON.", true)

    assert billing["type"] == "text"
    assert identity["type"] == "text"
    assert host["text"] == "Be useful\n\nReturn JSON."
  end

  test "removes identity paragraphs and rewrites harness names" do
    text = """
    You are Pi, a coding agent.

    Keep answers short.

    The Pi binary lives in /usr/bin/pi.
    """

    sanitized = Prompt.sanitize_system_text(text)

    refute sanitized =~ "You are Pi"
    assert sanitized =~ "Keep answers short."
    assert sanitized =~ "The Claude Code binary lives in /usr/bin/Claude Code."
  end

  test "technical-safe rewriting leaves paths and identifiers alone" do
    text = "Use the pi binary at /usr/bin/pi and the pi-mono repo."

    assert Prompt.sanitize_system_text(text, rewrite_mode: "technical-safe") ==
             "Use the Claude Code binary at /usr/bin/pi and the pi-mono repo."
  end

  test "a never-matching custom pattern disables rewriting" do
    assert Prompt.sanitize_system_text("Pi is here",
             rewrite_mode: "custom",
             rewrite_pattern: "(?!)"
           ) ==
             "Pi is here"
  end

  test "resolves the advertised Claude Code version" do
    assert Prompt.claude_code_version() == "2.1.280"
    assert Prompt.claude_code_version(claude_code_version: "9.9.9") == "9.9.9"
    assert Prompt.user_agent(claude_code_version: "1.2.3") == "claude-cli/1.2.3 (external, cli)"
  end

  test "sanitize_surrogates replaces invalid bytes" do
    assert Prompt.sanitize_surrogates("ok") == "ok"
    invalid = <<0xED, 0xA0, 0x80>>
    refute String.valid?(invalid)
    assert String.valid?(Prompt.sanitize_surrogates(invalid))
    assert Prompt.sanitize_surrogates(invalid) != invalid
  end
end

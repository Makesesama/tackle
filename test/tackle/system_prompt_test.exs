defmodule Tackle.SystemPromptTest do
  use ExUnit.Case, async: true

  alias Tackle.SystemPrompt

  defmodule Tool do
    use Tackle.Lib.Tool

    tool_name("example")
    description("Run the example capability.")

    input do
    end

    def run(_args, _context), do: {:ok, "ok"}
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "tackle-system-prompt-#{System.unique_integer([:positive, :monotonic])}"
      )

    home = Path.join(root, "home")
    project = Path.join(root, "project")
    cwd = Path.join(project, "apps/example")
    File.mkdir_p!(home)
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(root) end)
    %{cwd: cwd, home: home, project: project}
  end

  test "builds the default coding prompt with available tools and cwd", %{cwd: cwd, home: home} do
    assert {:ok, prompt} = SystemPrompt.build(cwd: cwd, home: home, tools: [Tool])

    assert prompt =~ "You are an expert coding assistant operating inside Tackle"
    assert prompt =~ "- example: Run the example capability."
    assert prompt =~ "Current working directory: #{cwd}"
  end

  test "does not recommend tools that are unavailable", %{cwd: cwd, home: home} do
    assert {:ok, prompt} = SystemPrompt.build(cwd: cwd, home: home, tools: [])

    assert prompt =~ "Available tools:\n(none)"
    refute prompt =~ "Use bash"
    refute prompt =~ "Use read"
  end

  test "layers global additions before global and ancestor AGENTS.md files", %{
    cwd: cwd,
    home: home,
    project: project
  } do
    File.write!(Path.join(home, "APPEND_SYSTEM.md"), "Global extra guidance.")
    File.write!(Path.join(home, "AGENTS.md"), "Global agent guidance.")
    File.write!(Path.join(project, "AGENTS.md"), "Project guidance.")
    File.write!(Path.join(cwd, "AGENTS.md"), "Nested guidance.")

    assert {:ok, prompt} = SystemPrompt.build(cwd: cwd, home: home, tools: [])

    assert_in_order(prompt, [
      "You are an expert coding assistant",
      "Global extra guidance.",
      "Global agent guidance.",
      "Project guidance.",
      "Nested guidance.",
      "Current working directory: #{cwd}"
    ])

    assert prompt =~ ~s(<project_instructions path="#{Path.join(home, "AGENTS.md")}">)
    assert prompt =~ ~s(<project_instructions path="#{Path.join(project, "AGENTS.md")}">)
    assert prompt =~ ~s(<project_instructions path="#{Path.join(cwd, "AGENTS.md")}">)
  end

  test "uses SYSTEM.md as the global base and an explicit base takes precedence", %{
    cwd: cwd,
    home: home
  } do
    File.write!(Path.join(home, "SYSTEM.md"), <<0xEF, 0xBB, 0xBF>> <> "Global base prompt.")

    assert {:ok, global_prompt} = SystemPrompt.build(cwd: cwd, home: home, tools: [])
    assert global_prompt =~ "Global base prompt."
    refute global_prompt =~ "expert coding assistant"

    assert {:ok, explicit_prompt} =
             SystemPrompt.build(base: "Explicit base prompt.", cwd: cwd, home: home, tools: [])

    assert explicit_prompt =~ "Explicit base prompt."
    refute explicit_prompt =~ "Global base prompt."
  end

  test "rejects invalid UTF-8 prompt files", %{cwd: cwd, home: home} do
    path = Path.join(home, "APPEND_SYSTEM.md")
    File.write!(path, <<0xFF>>)

    assert {:error, {:invalid_system_prompt_file, ^path, :invalid_utf8}} =
             SystemPrompt.build(cwd: cwd, home: home, tools: [])
  end

  defp assert_in_order(content, snippets) do
    {_offset, _length} =
      Enum.reduce(snippets, {0, byte_size(content)}, fn snippet, {offset, remaining} ->
        scope = binary_part(content, offset, remaining)
        assert {relative, length} = :binary.match(scope, snippet)
        next_offset = offset + relative + length
        {next_offset, byte_size(content) - next_offset}
      end)
  end
end

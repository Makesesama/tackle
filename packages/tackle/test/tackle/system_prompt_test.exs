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
    File.mkdir_p!(Path.join(project, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, cwd: cwd, home: home, project: project}
  end

  test "builds the default coding prompt with available tools and cwd", %{cwd: cwd, home: home} do
    assert {:ok, prompt} = SystemPrompt.build(cwd: cwd, home: home, tools: [Tool])

    assert prompt =~ "You are an expert coding assistant operating inside Tackle"
    assert prompt =~ "- example: Run the example capability."
    assert prompt =~ "Current working directory: #{cwd}"
  end

  test "read/1 keeps an unreadable file's error for the prompts that use it", %{
    cwd: cwd,
    home: home,
    project: project
  } do
    agents = Path.join(project, "AGENTS.md")
    File.write!(agents, "Project guidance.")
    File.chmod!(agents, 0o000)
    on_exit(fn -> File.chmod(agents, 0o600) end)

    assert {:ok, files} = SystemPrompt.read(cwd: cwd, home: home)
    assert {:error, {:system_prompt_file_unreadable, ^agents, :eacces}} = files.context_files

    assert {:error, {:system_prompt_file_unreadable, ^agents, :eacces}} =
             SystemPrompt.compose(files, cwd: cwd, tools: [])

    assert {:ok, prompt} =
             SystemPrompt.compose(files, base: "Lean.", cwd: cwd, instructions: false)

    assert prompt == "Lean.\n\nCurrent working directory: #{cwd}\n"

    # Not reading instructions leaves the file alone.
    assert {:ok, %{context_files: {:ok, []}, append: {:ok, nil}}} =
             SystemPrompt.read(cwd: cwd, home: home, instructions: false)
  end

  test "does not recommend tools that are unavailable", %{cwd: cwd, home: home} do
    assert {:ok, prompt} = SystemPrompt.build(cwd: cwd, home: home, tools: [])

    assert prompt =~ "Available tools:\n(none)"
    refute prompt =~ "Use bash"
    refute prompt =~ "Use read"
  end

  test "instructions: false skips APPEND_SYSTEM.md and AGENTS.md files", %{
    cwd: cwd,
    home: home,
    project: project
  } do
    File.write!(Path.join(home, "APPEND_SYSTEM.md"), "Global extra guidance.")
    File.write!(Path.join(project, "AGENTS.md"), "Project guidance.")

    assert {:ok, prompt} =
             SystemPrompt.build(
               base: "Assignment.",
               cwd: cwd,
               home: home,
               tools: [],
               instructions: false
             )

    assert prompt == "Assignment.\n\nCurrent working directory: #{cwd}\n"

    assert {:error, {:invalid_system_prompt_option, :instructions, "no"}} =
             SystemPrompt.build(cwd: cwd, home: home, instructions: "no")
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

  describe "the AGENTS.md search" do
    setup %{root: root, home: home} do
      # `user` is the user's home directory and `home` is `$TACKLE_HOME`.
      user = Path.join(root, "user")
      cwd = Path.join(user, "dev/repo/lib")
      File.mkdir_p!(cwd)

      for dir <- [root, user, Path.join(user, "dev"), Path.join(user, "dev/repo"), cwd],
          do: File.write!(Path.join(dir, "AGENTS.md"), "Guidance from #{dir}.")

      %{user: user, cwd: cwd, opts: [home: home, tools: [], user_home: user]}
    end

    test "without a Git root, stops at the home directory", %{root: root, user: user} = ctx do
      assert {:ok, prompt} = SystemPrompt.build([cwd: ctx.cwd] ++ ctx.opts)
      assert prompt =~ "Guidance from #{user}."
      assert prompt =~ "Guidance from #{ctx.cwd}."
      refute prompt =~ "Guidance from #{root}."
    end

    test "outside the home directory, covers only the working directory or the Git root",
         %{root: root, user: user} = ctx do
      outside = Path.join(root, "elsewhere/lib")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "AGENTS.md"), "Guidance from #{outside}.")
      File.write!(Path.join(root, "elsewhere/AGENTS.md"), "Guidance from elsewhere.")

      assert {:ok, prompt} = SystemPrompt.build([cwd: outside] ++ ctx.opts)
      assert prompt =~ "Guidance from #{outside}."
      refute prompt =~ "Guidance from elsewhere."
      refute prompt =~ "Guidance from #{root}."
      refute prompt =~ "Guidance from #{user}."

      File.mkdir_p!(Path.join(root, "elsewhere/.git"))
      assert {:ok, prompt} = SystemPrompt.build([cwd: outside] ++ ctx.opts)
      assert prompt =~ "Guidance from elsewhere."
      refute prompt =~ "Guidance from #{root}."
    end

    test "under the home directory, climbs past the Git root to the home directory",
         %{root: root, user: user} = ctx do
      File.mkdir_p!(Path.join(user, "dev/repo/.git"))

      assert {:ok, prompt} = SystemPrompt.build([cwd: ctx.cwd] ++ ctx.opts)

      assert_in_order(prompt, [
        "Guidance from #{user}.",
        "Guidance from #{user}/dev.",
        "Guidance from #{user}/dev/repo.",
        "Guidance from #{ctx.cwd}."
      ])

      refute prompt =~ "Guidance from #{root}."
    end
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

  test "includes available skills before the working directory", %{cwd: cwd, home: home} do
    skill = %Tackle.Skills.Skill{
      name: "brave-search",
      description: "Search the web.",
      path: "/tmp/brave-search/SKILL.md",
      dir: "/tmp/brave-search"
    }

    assert {:ok, prompt} =
             SystemPrompt.build(cwd: cwd, home: home, tools: [Tool], skills: [skill])

    assert prompt =~ "<available_skills>"
    assert prompt =~ "<name>brave-search</name>"
    assert_in_order(prompt, ["<available_skills>", "Current working directory: #{cwd}"])
  end

  test "rejects an invalid skills option", %{cwd: cwd, home: home} do
    assert {:error, {:invalid_system_prompt_option, :skills, :nope}} =
             SystemPrompt.build(cwd: cwd, home: home, tools: [], skills: :nope)
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

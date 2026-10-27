defmodule Tackle.SkillsTest do
  use ExUnit.Case, async: true

  alias Tackle.Skills
  alias Tackle.Skills.Skill

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "tackle-skills-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  describe "discover/1" do
    test "discovers a skill from the project .agents/skills directory", %{root: root} do
      project = git_project(root)
      path = write_skill(project, "brave-search", skill_file("brave-search", "Search the web."))

      assert %{skills: [skill], warnings: []} = Skills.discover(cwd: project, user_home: nil)

      assert skill == %Skill{
               name: "brave-search",
               description: "Search the web.",
               path: path,
               dir: Path.dirname(path)
             }
    end

    test "falls back to the parent directory name when name is absent", %{root: root} do
      project = git_project(root)
      write_skill(project, "pdf-tools", "---\ndescription: Handle PDFs.\n---\nbody\n")

      assert %{skills: [%Skill{name: "pdf-tools"}], warnings: []} =
               Skills.discover(cwd: project, user_home: nil)
    end

    test "recurses into grouping folders that contain SKILL.md", %{root: root} do
      project = git_project(root)
      write_skill(project, "grouping/nested", "---\ndescription: Nested.\n---\n")

      assert %{skills: [%Skill{name: "nested", description: "Nested."}], warnings: []} =
               Skills.discover(cwd: project, user_home: nil)
    end

    test "does not recurse below a directory that declares a skill", %{root: root} do
      project = git_project(root)
      write_skill(project, "outer", "---\ndescription: Outer.\n---\n")
      write_skill(project, "outer/inner", "---\ndescription: Inner.\n---\n")

      assert %{skills: [%Skill{name: "outer"}], warnings: []} =
               Skills.discover(cwd: project, user_home: nil)
    end

    test "warns and skips a skill without a description", %{root: root} do
      project = git_project(root)
      path = write_skill(project, "missing", "---\nname: missing\n---\n")

      assert %{skills: [], warnings: [%{path: ^path, message: message}]} =
               Skills.discover(cwd: project, user_home: nil)

      assert message =~ "description is required"
    end

    test "warns but loads a skill with an invalid name", %{root: root} do
      project = git_project(root)
      path = write_skill(project, "bad", "---\nname: Bad_Name\ndescription: Invalid.\n---\n")

      assert %{skills: [%Skill{name: "Bad_Name"}], warnings: [%{path: ^path}]} =
               Skills.discover(cwd: project, user_home: nil)
    end

    test "warns but loads a skill with an over-long description", %{root: root} do
      project = git_project(root)
      write_skill(project, "long", skill_file("long", String.duplicate("a", 1025)))

      assert %{skills: [%Skill{description: description}], warnings: [%{message: message}]} =
               Skills.discover(cwd: project, user_home: nil)

      assert String.length(description) == 1025
      assert message =~ "description exceeds"
    end

    test "normalizes multiline descriptions and ignores unknown fields", %{root: root} do
      project = git_project(root)

      write_skill(project, "multi", """
      ---
      name: multi
      description: |
        Extracts text from PDFs.
        Use when working with documents.
      author: someone
      ---
      """)

      assert %{skills: [%Skill{description: description}], warnings: []} =
               Skills.discover(cwd: project, user_home: nil)

      assert description == "Extracts text from PDFs. Use when working with documents."
    end

    test "keeps the nearest project skill on a name collision", %{root: root} do
      project = git_project(root)
      nested = Path.join(project, "apps/example")
      File.mkdir_p!(nested)

      write_skill(project, "dup", skill_file("dup", "Outer."))
      nearest = write_skill(nested, "dup", skill_file("dup", "Nearest."))

      assert %{skills: [%Skill{description: "Nearest.", path: ^nearest}], warnings: [warning]} =
               Skills.discover(cwd: nested, user_home: nil)

      assert warning.message =~ "already loaded"
    end

    test "discovers skills in ancestors up to the git repository root", %{root: root} do
      project = git_project(root)
      nested = Path.join(project, "apps/example")
      File.mkdir_p!(nested)
      write_skill(project, "root-skill", skill_file("root-skill", "From the root."))

      assert %{skills: [%Skill{name: "root-skill"}], warnings: []} =
               Skills.discover(cwd: nested, user_home: nil)
    end

    test "does not walk past the git repository root", %{root: root} do
      outside = Path.join(root, "outside")
      File.mkdir_p!(outside)
      write_skill(outside, "outside-skill", skill_file("outside-skill", "Outside."))

      project = git_project(root)
      write_skill(project, "inside", skill_file("inside", "Inside."))

      assert %{skills: skills} = Skills.discover(cwd: project, user_home: nil)
      assert Enum.map(skills, & &1.name) == ["inside"]
    end

    test "user skills load after project skills", %{root: root} do
      project = git_project(root)
      user_home = Path.join(root, "home")
      File.mkdir_p!(user_home)
      write_skill(project, "project", skill_file("project", "Project."))
      write_skill_dir(user_home, "user", skill_file("user", "User."))

      assert %{skills: skills, warnings: []} =
               Skills.discover(cwd: project, user_home: user_home)

      assert Enum.map(skills, & &1.name) == ["project", "user"]
    end

    test "project skills win over user skills on a collision", %{root: root} do
      project = git_project(root)
      user_home = Path.join(root, "home")
      File.mkdir_p!(user_home)
      winner = write_skill(project, "shared", skill_file("shared", "Project."))
      write_skill_dir(user_home, "shared", skill_file("shared", "User."))

      assert %{skills: [%Skill{path: ^winner}], warnings: [warning]} =
               Skills.discover(cwd: project, user_home: user_home)

      assert warning.message =~ "already loaded"
    end

    test "skips user discovery when no home is available", %{root: root} do
      project = git_project(root)
      write_skill(project, "only", skill_file("only", "Only."))

      assert %{skills: [%Skill{name: "only"}]} = Skills.discover(cwd: project, user_home: nil)
    end

    test "without :user_home, user skills come from the default home", %{root: root} do
      project = git_project(root)
      user_home = Path.join(root, "home")
      write_skill_dir(user_home, "user", skill_file("user", "User."))

      assert %{skills: [%Skill{name: "user"}], warnings: []} =
               Skills.discover(cwd: project, env: %{"HOME" => user_home})
    end

    test "without a Git root, searches up to the home directory or only the working directory",
         %{root: root} do
      # A shared parent such as /tmp, where other users can plant skills.
      write_skill(root, "planted", skill_file("planted", "Planted."))
      cwd = Path.join(root, "project/apps")
      File.mkdir_p!(cwd)
      write_skill(Path.join(root, "project"), "parent", skill_file("parent", "Parent."))

      assert %{skills: [], warnings: []} = Skills.discover(cwd: cwd, user_home: nil)

      home = Path.join(root, "project")

      assert %{skills: [%Skill{name: "parent"}], warnings: []} =
               Skills.discover(cwd: cwd, user_home: home)
    end

    test "returns an empty result when no skill exists", %{root: root} do
      project = git_project(root)
      assert %{skills: [], warnings: []} = Skills.discover(cwd: project, user_home: nil)
    end
  end

  describe "builtin/2" do
    test "builds a built-in skill from SKILL.md text" do
      markdown = """
      ---
      name: guide
      description: >
        Explains
        the tool.
      ---

      # Guide

      Body text.
      """

      assert {:ok, skill} = Skills.builtin(markdown, requires_tools: ["tool_a"])

      assert skill == %Skill{
               name: "guide",
               description: "Explains the tool.",
               content: "# Guide\n\nBody text.",
               source: :builtin,
               requires_tools: ["tool_a"]
             }
    end

    test "rejects invalid names, missing descriptions, and empty bodies" do
      assert {:error, {:invalid_builtin_skill, {:name, "Bad Name"}}} =
               Skills.builtin(skill_file("Bad Name", "d"))

      assert {:error, {:invalid_builtin_skill, :description_required}} =
               Skills.builtin("---\nname: guide\n---\nBody")

      assert {:error, {:invalid_builtin_skill, :empty_body}} =
               Skills.builtin("---\nname: guide\ndescription: d\n---\n\n")

      assert {:error, {:invalid_builtin_skill, :unterminated_frontmatter}} =
               Skills.builtin("---\nname: guide\n")

      assert {:error, {:invalid_builtin_skill, {:requires_tools, [:read]}}} =
               Skills.builtin(skill_file("guide", "d"), requires_tools: [:read])
    end
  end

  describe "discover/1 with built-in skills" do
    test "built-in skills rank after file skills", %{root: root} do
      project = git_project(root)
      write_skill(project, "local", skill_file("local", "A file skill."))
      builtin = builtin!("bundled", "A built-in skill.")

      assert %{skills: [%Skill{name: "local"}, ^builtin], warnings: []} =
               Skills.discover(cwd: project, user_home: nil, builtins: [builtin])
    end

    test "a file skill replaces a built-in skill of the same name without a warning", %{
      root: root
    } do
      project = git_project(root)
      path = write_skill(project, "bundled", skill_file("bundled", "My override."))

      assert %{skills: [%Skill{source: :file, path: ^path}], warnings: []} =
               Skills.discover(
                 cwd: project,
                 user_home: nil,
                 builtins: [builtin!("bundled", "Built in.")]
               )
    end
  end

  describe "load/2" do
    test "returns a file skill's body without frontmatter", %{root: root} do
      project = git_project(root)
      write_skill(project, "lint", skill_file("lint", "Lint."))
      %{skills: [skill]} = Skills.discover(cwd: project, user_home: nil)

      assert Skills.load(skill) == {:ok, "body"}
    end

    test "returns a built-in skill's content" do
      assert Skills.load(builtin!("bundled", "d")) == {:ok, "body"}
    end

    test "reports unreadable, non-UTF-8, and malformed files", %{root: root} do
      path = Path.join(root, "SKILL.md")
      skill = %Skill{name: "s", description: "d", path: path, dir: root}

      assert {:error, :enoent} = Skills.load(skill)

      File.write!(path, <<0xFF, 0xFE>>)
      assert {:error, :invalid_utf8} = Skills.load(skill)

      File.write!(path, "---\nname: s\n")
      assert {:error, :unterminated_frontmatter} = Skills.load(skill)
    end
  end

  describe "available/2" do
    test "keeps skills whose required tools are all present" do
      plain = builtin!("plain", "d")
      needs_read = builtin!("needs-read", "d", requires_tools: ["read"])
      needs_both = builtin!("needs-both", "d", requires_tools: ["read", "missing"])

      assert Skills.available([plain, needs_read, needs_both], [Tackle.Tools.Read]) ==
               [plain, needs_read]

      assert Skills.available([plain, needs_read], ["bash"]) == [plain]
    end
  end

  describe "format_for_prompt/2" do
    test "renders visible skills as an available_skills block" do
      skill = %Skill{
        name: "brave-search",
        description: "Search <the> web & more.",
        path: "/tmp/brave-search/SKILL.md",
        dir: "/tmp/brave-search"
      }

      prompt = Skills.format_for_prompt([skill], tools: [])

      assert prompt =~ "<available_skills>"
      assert prompt =~ "    <name>brave-search</name>"
      assert prompt =~ "    <description>Search &lt;the&gt; web &amp; more.</description>"
      assert prompt =~ "    <directory>/tmp/brave-search</directory>"
      assert prompt =~ "Use the load_skill tool to load a skill's instructions"
      assert prompt =~ "resolve it against the skill's directory"
    end

    test "omits skills that disable model invocation" do
      skill = %Skill{
        name: "manual",
        description: "d",
        path: "/tmp/manual/SKILL.md",
        dir: "/tmp/manual",
        disable_model_invocation: true
      }

      assert Skills.format_for_prompt([skill], tools: []) == ""
    end

    test "renders built-in skills without a directory" do
      prompt = Skills.format_for_prompt([builtin!("bundled", "Built in.")], tools: [])

      assert prompt =~ "    <name>bundled</name>"
      assert prompt =~ "Use the load_skill tool to load a skill's instructions"
      refute prompt =~ "<directory>"
      refute prompt =~ "relative path"
    end

    test "omits skills whose required tools are missing" do
      skill = builtin!("bundled", "Built in.", requires_tools: ["run_workflow"])

      assert Skills.format_for_prompt([skill], tools: [Tackle.Tools.Read]) == ""
      assert Skills.format_for_prompt([skill], tools: ["run_workflow"]) =~ "bundled"
    end

    test "renders file and built-in skills under one loading instruction" do
      file = %Skill{name: "s", description: "d", path: "/tmp/s/SKILL.md", dir: "/tmp/s"}

      prompt =
        Skills.format_for_prompt([file, builtin!("bundled", "d")], tools: [Tackle.Tools.Read])

      refute prompt =~ "read tool"
      assert [_before, _after] = String.split(prompt, "load_skill")
      assert prompt =~ "<directory>/tmp/s</directory>"
      assert prompt =~ "<name>bundled</name>"
    end

    test "returns an empty string when there are no skills" do
      assert Skills.format_for_prompt([], tools: []) == ""
    end
  end

  defp builtin!(name, description, opts \\ []) do
    {:ok, skill} = Skills.builtin(skill_file(name, description), opts)
    skill
  end

  defp git_project(root) do
    project = Path.join(root, "project")
    File.mkdir_p!(Path.join(project, ".git"))
    project
  end

  defp skill_file(name, description) do
    "---\nname: #{name}\ndescription: #{description}\n---\nbody\n"
  end

  defp write_skill(project, relative, contents) do
    dir = Path.join([project, ".agents", "skills", relative])
    File.mkdir_p!(dir)
    path = Path.join(dir, "SKILL.md")
    File.write!(path, contents)
    path
  end

  defp write_skill_dir(user_home, relative, contents) do
    dir = Path.join([user_home, ".agents", "skills", relative])
    File.mkdir_p!(dir)
    path = Path.join(dir, "SKILL.md")
    File.write!(path, contents)
    path
  end
end

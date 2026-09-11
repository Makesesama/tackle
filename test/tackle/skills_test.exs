defmodule Tackle.SkillsTest do
  use ExUnit.Case, async: true

  alias Tackle.Skills
  alias Tackle.Skills.{Frontmatter, Skill}

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

    test "returns an empty result when no skill exists", %{root: root} do
      project = git_project(root)
      assert %{skills: [], warnings: []} = Skills.discover(cwd: project, user_home: nil)
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
      assert prompt =~ "    <location>/tmp/brave-search/SKILL.md</location>"
    end

    test "recommends the read tool when it is available" do
      skill = %Skill{
        name: "s",
        description: "d",
        path: "/tmp/s/SKILL.md",
        dir: "/tmp/s"
      }

      prompt = Skills.format_for_prompt([skill], tools: [Tackle.Tools.Read])
      assert prompt =~ "Use the read tool to load a skill's file"
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

    test "returns an empty string when there are no skills" do
      assert Skills.format_for_prompt([], tools: []) == ""
    end
  end

  describe "Frontmatter.parse/1" do
    test "returns an empty map without a fence" do
      assert {:ok, %{}} = Frontmatter.parse("just some markdown")
    end

    test "returns an error for an unterminated fence" do
      assert {:error, :unterminated_frontmatter} = Frontmatter.parse("---\nname: x\n")
    end

    test "parses quoted and boolean scalars" do
      assert {:ok, frontmatter} =
               Frontmatter.parse("---\ndescription: \"Quoted: value\"\nflag: true\n---\n")

      assert frontmatter["description"] == "Quoted: value"
      assert frontmatter["flag"] == true
    end

    test "ignores comment lines" do
      assert {:ok, frontmatter} =
               Frontmatter.parse("---\n# a comment\ndescription: Value\n---\n")

      assert frontmatter == %{"description" => "Value"}
    end

    test "treats an unterminated flow collection as missing" do
      assert {:ok, frontmatter} = Frontmatter.parse("---\ndescription: [unclosed\n---\n")

      assert frontmatter["description"] == nil
    end
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

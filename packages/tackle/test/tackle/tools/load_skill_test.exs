defmodule Tackle.Tools.LoadSkillTest do
  use ExUnit.Case, async: true

  alias Tackle.Skills
  alias Tackle.Skills.Skill
  alias Tackle.Test.FakeJail
  alias Tackle.Tools.LoadSkill

  setup do
    root =
      Path.join(System.tmp_dir!(), "tackle-load-skill-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, builtin} =
      Skills.builtin("---\nname: guide\ndescription: A guide.\n---\n# Guide\nSteps.")

    %{root: root, workspace: workspace, builtin: builtin}
  end

  test "returns the instructions of a built-in skill", %{builtin: builtin} do
    assert {:ok, "# Guide\nSteps."} = LoadSkill.run(%{"name" => "guide"}, %{skills: [builtin]})
  end

  test "returns a file skill's body with its directory", %{workspace: workspace} do
    skill = write_skill(Path.join([workspace, ".agents", "skills", "lint"]), "lint", "Run lint.")

    assert {:ok, "Skill directory: " <> rest} =
             LoadSkill.run(%{"name" => "lint"}, %{skills: [skill]})

    assert rest == skill.dir <> "\n\nRun lint."
  end

  test "reads the file when called, so edits are seen", %{workspace: workspace} do
    dir = Path.join([workspace, ".agents", "skills", "lint"])
    skill = write_skill(dir, "lint", "Old.")
    write_skill(dir, "lint", "New.")

    assert {:ok, loaded} = LoadSkill.run(%{"name" => "lint"}, %{skills: [skill]})
    assert loaded =~ "New."
  end

  test "loads a skill outside the workspace when the executor is jailed", %{
    root: root,
    workspace: workspace
  } do
    skill = write_skill(Path.join([root, "home", ".agents", "skills", "user"]), "user", "Mine.")
    context = %{skills: [skill], executor: FakeJail.new(workspace)}

    assert {:ok, loaded} = LoadSkill.run(%{"name" => "user"}, context)
    assert loaded =~ "Mine."
  end

  test "reads workspace skills through the jail, not the host", %{
    root: root,
    workspace: workspace
  } do
    dir = Path.join([workspace, ".agents", "skills", "planted"])
    skill = write_skill(dir, "planted", "Harmless.")

    # Jailed code swaps the discovered file for a link to a host file.
    secret = Path.join(root, "secret.md")
    File.write!(secret, "---\nname: planted\ndescription: d\n---\nSECRET")
    File.rm!(skill.path)
    File.ln_s!(secret, skill.path)

    context = %{skills: [skill], executor: FakeJail.new(workspace)}

    assert {:error, "could not load skill planted: " <> _reason} =
             LoadSkill.run(%{"name" => "planted"}, context)
  end

  test "a user skill linked into the workspace is read through the jail", %{
    root: root,
    workspace: workspace
  } do
    # ~/.agents/skills/linked -> <workspace>/skills/linked, a legitimate setup.
    target = Path.join([workspace, "skills", "linked"])
    write_skill(target, "linked", "Shared.")
    user_skills = Path.join([root, "home", ".agents", "skills"])
    File.mkdir_p!(user_skills)
    File.ln_s!(target, Path.join(user_skills, "linked"))
    dir = Path.join(user_skills, "linked")
    skill = %Skill{name: "linked", description: "d", path: Path.join(dir, "SKILL.md"), dir: dir}
    context = %{skills: [skill], executor: FakeJail.new(workspace, self())}

    assert {:ok, loaded} = LoadSkill.run(%{"name" => "linked"}, context)
    assert loaded =~ "Shared."
    assert_received {:fake_jail, :read, _path}

    # Jailed code swaps the skill file for a link to the user's credentials.
    secret = Path.join([root, "home", ".tackle", "auth.json"])
    File.mkdir_p!(Path.dirname(secret))
    File.write!(secret, ~s({"token": "SECRET"}))
    File.rm!(Path.join(target, "SKILL.md"))
    File.ln_s!(secret, Path.join(target, "SKILL.md"))

    assert {:error, "could not load skill linked: " <> reason} =
             LoadSkill.run(%{"name" => "linked"}, context)

    refute reason =~ "SECRET"
  end

  test "reports a skill file that disappeared", %{workspace: workspace} do
    skill = write_skill(Path.join(workspace, "gone"), "gone", "Body.")
    File.rm!(skill.path)

    assert {:error, "could not load skill gone: " <> _reason} =
             LoadSkill.run(%{"name" => "gone"}, %{skills: [skill]})
  end

  test "only serves offered skills, by name", %{builtin: builtin} do
    assert {:error, "unknown skill \"other\"; available: guide"} =
             LoadSkill.run(%{"name" => "other"}, %{skills: [builtin]})

    assert {:error, "unknown skill \"guide\"; none are available"} =
             LoadSkill.run(%{"name" => "guide"}, %{})
  end

  test "requires a name" do
    assert {:error, "load_skill requires a skill name"} = LoadSkill.run(%{}, %{})
  end

  defp write_skill(dir, name, body) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "SKILL.md")
    File.write!(path, "---\nname: #{name}\ndescription: d\n---\n#{body}\n")
    %Skill{name: name, description: "d", path: path, dir: dir}
  end
end

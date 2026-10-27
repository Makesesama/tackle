defmodule Tackle.ProjectFilesTest do
  use ExUnit.Case, async: true

  alias Tackle.{Agents, Config, ProjectFiles, Skills, SystemPrompt}
  alias Tackle.Test.FakeJail

  setup do
    root =
      Path.join(System.tmp_dir!(), "tackle-project-files-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    secret = Path.join(root, "home/.tackle/auth.json")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.dirname(secret))
    File.write!(secret, "SECRET-TOKEN")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace, secret: secret}
  end

  describe "routing" do
    test "sends workspace paths to the executor and others to the host", %{
      root: root,
      workspace: workspace
    } do
      files = ProjectFiles.new(executor: FakeJail.new(workspace, self()))
      inside = Path.join(workspace, "AGENTS.md")
      outside = Path.join(root, "AGENTS.md")
      File.write!(inside, "inside")
      File.write!(outside, "outside")

      assert {:ok, "inside"} = ProjectFiles.read(files, inside)
      assert_received {:fake_jail, :read, ^inside}
      assert {:ok, "outside"} = ProjectFiles.read(files, outside)
      refute_received {:fake_jail, _op, ^outside}

      assert ProjectFiles.dir?(files, workspace)
      assert_received {:fake_jail, :stat, ^workspace}
      assert {:ok, ["AGENTS.md"]} = ProjectFiles.list(files, workspace)
      assert ProjectFiles.regular?(files, inside)
      refute ProjectFiles.exists?(files, Path.join(workspace, "missing"))
    end

    test "matches whole path components and defaults to the local executor", %{root: root} do
      files = ProjectFiles.new(executor: FakeJail.new(Path.join(root, "work")))

      assert ProjectFiles.in_workspace?(files, Path.join(root, "work"))
      assert ProjectFiles.in_workspace?(files, Path.join(root, "work/a/../b"))
      refute ProjectFiles.in_workspace?(files, Path.join(root, "workspace"))
      refute ProjectFiles.in_workspace?(files, Path.join(root, "work/.."))
      assert ProjectFiles.in_workspace?(ProjectFiles.new(executor: FakeJail.new("/")), "/etc")
      refute ProjectFiles.in_workspace?(ProjectFiles.new(), "/etc")
      assert ProjectFiles.new(executor: nil).executor == Tackle.Executor.local()
    end
  end

  test "a parent of the working directory inside the jail's mount goes through the jail", %{
    workspace: workspace,
    secret: secret,
    root: root
  } do
    # The jail mounts the repository root while the agent works in a subdirectory.
    cwd = Path.join(workspace, "apps/cli")
    File.mkdir_p!(cwd)
    File.ln_s!(secret, Path.join(workspace, "AGENTS.md"))
    opts = [cwd: cwd, home: Path.join(root, "home/.tackle"), tools: []]

    assert {:ok, prompt} = SystemPrompt.build([executor: FakeJail.new(workspace)] ++ opts)
    refute prompt =~ "SECRET-TOKEN"
  end

  describe "planted symlinks do not leak host files" do
    test "AGENTS.md", %{workspace: workspace, secret: secret, root: root} do
      File.ln_s!(secret, Path.join(workspace, "AGENTS.md"))
      home = Path.join(root, "home/.tackle")
      opts = [cwd: workspace, home: home, tools: []]

      # Without the executor the host follows the link, which is what jailed
      # code would exploit.
      assert {:ok, local} = SystemPrompt.build(opts)
      assert local =~ "SECRET-TOKEN"

      assert {:ok, jailed} = SystemPrompt.build([executor: FakeJail.new(workspace)] ++ opts)
      refute jailed =~ "SECRET-TOKEN"
    end

    test "host files linked into the workspace go through the jail", %{
      workspace: workspace,
      secret: secret,
      root: root
    } do
      # ~/AGENTS.md -> <workspace>/AGENTS.md, which jailed code points at a
      # host file.
      user = Path.join(root, "user")
      cwd = Path.join(user, "project")
      File.mkdir_p!(cwd)
      File.ln_s!(secret, Path.join(workspace, "AGENTS.md"))
      File.ln_s!(Path.join(workspace, "AGENTS.md"), Path.join(user, "AGENTS.md"))
      File.write!(Path.join(cwd, "AGENTS.md"), "Project guidance.")
      opts = [cwd: cwd, home: Path.join(root, "home/.tackle"), user_home: user, tools: []]

      assert {:ok, local} = SystemPrompt.build(opts)
      assert local =~ "SECRET-TOKEN"

      assert {:ok, jailed} = SystemPrompt.build([executor: FakeJail.new(workspace)] ++ opts)
      assert jailed =~ "Project guidance."
      refute jailed =~ "SECRET-TOKEN"

      # A linked directory, including through `..` in the link, routes the same way.
      File.mkdir_p!(Path.join(workspace, "docs"))
      File.ln_s!(secret, Path.join(workspace, "docs/leak.md"))
      File.ln_s!(Path.join(workspace, "docs/../docs"), Path.join(root, "docs-link"))
      files = ProjectFiles.new(executor: FakeJail.new(workspace, self()))
      assert {:error, :enoent} = ProjectFiles.read(files, Path.join(root, "docs-link/leak.md"))
      assert_received {:fake_jail, :read, _path}
    end

    test "host symlink loops are an error, not a hang", %{workspace: workspace, root: root} do
      File.ln_s!(Path.join(root, "loop-b"), Path.join(root, "loop-a"))
      File.ln_s!(Path.join(root, "loop-a"), Path.join(root, "loop-b"))
      files = ProjectFiles.new(executor: FakeJail.new(workspace))

      assert {:error, :eloop} = ProjectFiles.read(files, Path.join(root, "loop-a/file"))
    end

    test "skills", %{workspace: workspace, root: root} do
      outside = Path.join(root, "outside-skill")
      File.mkdir_p!(outside)

      File.write!(
        Path.join(outside, "SKILL.md"),
        "---\nname: leaked\ndescription: SECRET-TOKEN\n---\nbody\n"
      )

      File.mkdir_p!(Path.join(workspace, ".agents/skills"))
      File.ln_s!(outside, Path.join(workspace, ".agents/skills/leaked"))
      opts = [cwd: workspace, user_home: nil]

      assert [%{name: "leaked"}] = Skills.discover(opts).skills
      assert [] = Skills.discover([executor: FakeJail.new(workspace)] ++ opts).skills
    end

    test "project agent definitions", %{workspace: workspace, secret: secret, root: root} do
      File.mkdir_p!(Path.join(workspace, ".tackle/agents"))
      File.ln_s!(secret, Path.join(workspace, ".tackle/agents/leak.md"))

      opts = [
        cwd: workspace,
        env: %{"TACKLE_HOME" => Path.join(root, "home/.tackle")},
        builtins: []
      ]

      assert [%{path: _path}] = Agents.discover(opts).warnings

      assert %{definitions: [], warnings: []} =
               Agents.discover([executor: FakeJail.new(workspace)] ++ opts)
    end
  end

  describe "a hostile executor cannot exhaust the host" do
    test "reads stop at 1 MiB", %{workspace: workspace} do
      path = Path.join(workspace, "AGENTS.md")
      files = ProjectFiles.new(executor: {Tackle.Test.EndlessReads, workspace})

      assert {:error, :too_large} = ProjectFiles.read(files, path)

      File.write!(path, :binary.copy("x", 1_024 * 1_024))
      assert {:ok, data} = ProjectFiles.read(ProjectFiles.new(), path)
      assert byte_size(data) == 1_024 * 1_024
      File.write!(path, :binary.copy("x", 1_024 * 1_024 + 1))
      assert {:error, :too_large} = ProjectFiles.read(ProjectFiles.new(), path)
    end

    @tag :capture_log
    test "directory walks are bounded even with symlink loops", %{workspace: workspace} do
      skills = Path.join(workspace, ".agents/skills")
      File.mkdir_p!(Path.join(skills, "real"))
      for name <- ~w(a b c d e f), do: File.ln_s!(".", Path.join(skills, name))
      File.write!(Path.join(skills, "real/SKILL.md"), "---\nname: real\ndescription: d\n---\n")

      {elapsed, discovery} =
        :timer.tc(fn ->
          Skills.discover(cwd: workspace, user_home: nil, executor: FakeJail.new(workspace))
        end)

      assert Enum.any?(discovery.skills, &(&1.name == "real"))
      assert elapsed < 10_000_000

      visited = ProjectFiles.walk(ProjectFiles.new(), skills, &[{:file, &1}, {:dir, &1}])
      assert Enum.count(visited) == 256
    end

    @tag :capture_log
    test "a truncated walk keeps the files already listed" do
      # The first directory's subtree never ends; the file listed after it
      # is still returned.
      visit = fn
        "root" -> [{:dir, "root/deep"}, {:file, "root/listed"}]
        dir -> [{:dir, dir <> "/x"}]
      end

      assert ProjectFiles.walk(ProjectFiles.new(), "root", visit) == ["root/listed"]
    end
  end

  describe "project bounds" do
    test "git_root finds the nearest repository, through the router", %{workspace: workspace} do
      nested = Path.join(workspace, "apps/cli")
      File.mkdir_p!(nested)
      files = ProjectFiles.new(executor: FakeJail.new(workspace, self()))

      assert ProjectFiles.git_root(files, nested) == nil
      File.mkdir_p!(Path.join(workspace, ".git"))
      assert ProjectFiles.git_root(files, Path.join(nested, "..")) == workspace
      assert_received {:fake_jail, :stat, _path}
    end

    test "nearest_project_file stops at the Git root", %{root: root, workspace: workspace} do
      nested = Path.join(workspace, "apps/cli")
      File.mkdir_p!(nested)
      File.mkdir_p!(Path.join(root, ".tackle"))
      File.write!(Path.join(root, ".tackle/config.json"), "{}")
      files = ProjectFiles.new(user_home: root)

      assert ProjectFiles.nearest_project_file(files, nested, ".tackle/config.json") ==
               Path.join(root, ".tackle/config.json")

      assert ProjectFiles.nearest_project_dir(files, nested, ".tackle") ==
               Path.join(root, ".tackle")

      File.mkdir_p!(Path.join(workspace, ".git"))
      assert ProjectFiles.nearest_project_file(files, nested, ".tackle/config.json") == nil
    end

    test "without a Git root, the search stops at the home directory or the working directory",
         %{root: root, workspace: workspace} do
      nested = Path.join(workspace, "apps/cli")
      File.mkdir_p!(nested)
      # Any local user could plant these in a shared parent such as /tmp.
      File.mkdir_p!(Path.join(root, ".tackle/agents"))

      home = ProjectFiles.new(user_home: workspace)

      assert ProjectFiles.ancestors(home, nested) == [
               nested,
               Path.join(workspace, "apps"),
               workspace
             ]

      assert ProjectFiles.nearest_project_dir(home, nested, ".tackle/agents") == nil

      elsewhere = ProjectFiles.new(user_home: Path.join(root, "other"))
      assert ProjectFiles.ancestors(elsewhere, nested) == [nested]
      assert ProjectFiles.ancestors(ProjectFiles.new(user_home: nil), nested) == [nested]
      assert ProjectFiles.ancestors(ProjectFiles.new(env: %{}), nested) == [nested]

      assert ProjectFiles.ancestors(ProjectFiles.new(env: %{"HOME" => root}), workspace) ==
               [workspace, root]

      assert ProjectFiles.ancestors(home, nested, beyond_git_root: true) ==
               ProjectFiles.ancestors(home, nested)

      File.mkdir_p!(Path.join(nested, ".git"))
      assert ProjectFiles.ancestors(home, nested) == [nested]

      assert ProjectFiles.ancestors(home, nested, beyond_git_root: true) ==
               [nested, Path.join(workspace, "apps"), workspace]
    end

    test "the home directory bounds the search through its symlinks", %{root: root} do
      real = Path.join(root, "real-home")
      cwd = Path.join(real, "project")
      File.mkdir_p!(cwd)
      File.ln_s!(real, Path.join(root, "home-link"))
      files = ProjectFiles.new(user_home: Path.join(root, "home-link"))

      assert ProjectFiles.ancestors(files, cwd) == [cwd, real]
    end

    test "same_dir? compares expanded paths and file identity", %{
      root: root,
      workspace: workspace
    } do
      link = Path.join(root, "link")
      File.ln_s!(workspace, link)

      assert ProjectFiles.same_dir?(workspace, Path.join(workspace, "../workspace"))
      assert ProjectFiles.same_dir?(link, workspace)
      refute ProjectFiles.same_dir?(root, workspace)
      refute ProjectFiles.same_dir?(Path.join(root, "missing"), Path.join(root, "absent"))
    end
  end

  test "Config rejects a malformed executor instead of falling back to local" do
    for executor <- [:jailed, {"Module", nil}, {Tackle.Test.NotAnExecutor, nil}, {String, nil}] do
      assert {:error, {:invalid_option, :executor, ^executor}} =
               Config.new(
                 providers: [Tackle.Test.Adapter],
                 model: "test/echo",
                 context: %{executor: executor}
               )
    end
  end
end

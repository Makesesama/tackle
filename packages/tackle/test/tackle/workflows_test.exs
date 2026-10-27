defmodule Tackle.WorkflowsTest do
  use ExUnit.Case, async: true

  alias Tackle.Test.FakeJail
  alias Tackle.Workflows

  setup do
    root = Path.join(System.tmp_dir!(), "tackle-workflows-#{System.unique_integer([:positive])}")
    cwd = Path.join(root, "project")
    home = Path.join(root, "home")
    File.mkdir_p!(cwd)
    File.mkdir_p!(Path.join(cwd, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, cwd: cwd, home: home, opts: [cwd: cwd, env: %{"TACKLE_HOME" => home}]}
  end

  test "flat discovery, sorted names, project precedence, and warnings", %{
    cwd: cwd,
    home: home,
    opts: opts
  } do
    user = Path.join(home, "workflows")
    project = Path.join(cwd, ".tackle/workflows")
    put(user, "report.lua", "-- user\nreturn 1")
    put(user, "alpha.lua", "-- Alpha\nreturn 2")
    put(project, "report.lua", "-- Project report\nreturn 3")
    put(project, "Bad_name.lua", "return 1")
    put(project, "bad--name.lua", "return 1")
    put(project, "notes.md", "ignored")
    put(Path.join(project, "nested"), "hidden.lua", "return 1")
    assert %{workflows: [alpha, report], warnings: warnings} = Workflows.discover(opts)
    assert alpha.name == "alpha"
    assert alpha.source == :user
    assert report.name == "report"
    assert report.source == :project
    assert report.description == "Project report"
    assert report.path == Path.join(project, "report.lua")
    assert Enum.map(warnings, &Path.basename(&1.path)) == ["Bad_name.lua", "bad--name.lua"]
  end

  test "uses the nearest directory and stops at the Git root", %{root: root, cwd: cwd, opts: opts} do
    put(Path.join(root, ".tackle/workflows"), "outside.lua", "return 1")
    assert Workflows.discover(opts).workflows == []
    parent = Path.join(cwd, ".tackle/workflows")
    put(parent, "parent.lua", "return 1")
    child = Path.join(cwd, "child")
    File.mkdir_p!(child)
    child_opts = Keyword.put(opts, :cwd, child)
    assert Workflows.project_dir(child_opts) == parent
    assert [%{name: "parent"}] = Workflows.discover(child_opts).workflows
    nearest = Path.join(child, ".tackle/workflows")
    put(nearest, "child.lua", "return 1")
    assert Workflows.project_dir(child_opts) == nearest
    assert [%{name: "child"}] = Workflows.discover(child_opts).workflows
  end

  test "the shared ancestor search preserves Agents discovery", %{
    cwd: cwd,
    root: root,
    opts: opts
  } do
    script = "---\nname: scout\ndescription: Inspect code\n---\nInspect the project."
    put(Path.join(root, ".tackle/agents"), "outside.md", script)
    assert Tackle.Agents.discover(opts).definitions == []
    agents = Path.join(cwd, ".tackle/agents")
    put(Path.join(agents, "nested"), "scout.md", script)
    child = Path.join(cwd, "child")
    File.mkdir_p!(child)
    child_opts = Keyword.put(opts, :cwd, child)
    assert [%{name: "scout", source: :project}] = Tackle.Agents.discover(child_opts).definitions
    File.mkdir_p!(Path.join(child, ".tackle/agents"))
    assert Tackle.Agents.discover(child_opts).definitions == []
  end

  test "first-line descriptions only, excluding block comments", %{cwd: cwd, opts: opts} do
    dir = Path.join(cwd, ".tackle/workflows")

    for {name, script} <- [
          {"line", "--  Clean up modules  \r\nreturn 1"},
          {"block", "--[[ Not a description ]]\nreturn 1"},
          {"indented", "  -- Indented description\nreturn 1"},
          {"code", "return 1 -- nope"},
          {"later", "\n-- Later"},
          {"empty", ""}
        ] do
      put(dir, name <> ".lua", script)
    end

    descriptions = Map.new(Workflows.discover(opts).workflows, &{&1.name, &1.description})

    assert descriptions == %{
             "line" => "Clean up modules",
             "indented" => "Indented description",
             "block" => "",
             "code" => "",
             "later" => "",
             "empty" => ""
           }
  end

  test "fetch and loader discover files created and edited mid-session", %{opts: opts} do
    loader = Workflows.loader(opts)
    assert {:error, {:unknown_workflow, "report", []}} = Workflows.fetch("report", opts)
    assert {:ok, path} = Workflows.create("report", "-- Report\nreturn 1", opts)
    assert {:ok, workflow, "-- Report\nreturn 1"} = Workflows.fetch("report", opts)
    assert workflow.path == path
    assert {:ok, "-- Report\nreturn 1"} = loader.("report")
    assert :ok = Workflows.save(path, "return 2", opts)
    assert {:ok, "return 2"} = loader.("report")
    assert {:error, {:unknown_workflow, "missing", ["report"]}} = Workflows.fetch("missing", opts)
    assert {:error, message} = loader.("missing")
    assert message =~ "Available workflows: report"
  end

  test "empty loader errors explain both locations", %{opts: opts, home: home, cwd: cwd} do
    assert {:error, message} = Workflows.loader(opts).("missing")
    assert message =~ "No saved workflows exist"
    assert message =~ Path.join(cwd, ".tackle/workflows")
    assert message =~ Path.join(home, "workflows")
  end

  test "jailed empty loader errors mention only the writable project location", %{
    opts: opts,
    cwd: cwd,
    home: home
  } do
    opts = Keyword.put(opts, :executor, FakeJail.new(cwd))
    assert {:error, message} = Workflows.loader(opts).("missing")
    assert message =~ "No saved workflows exist"
    assert message =~ Path.join(cwd, ".tackle/workflows")
    refute message =~ home
    refute message =~ "$TACKLE_HOME"
  end

  test "fetch and loader reject path traversal, nested paths and trailing newlines", %{
    opts: opts,
    cwd: cwd,
    home: home
  } do
    project = Path.join(cwd, ".tackle/workflows")
    user = Path.join(home, "workflows")

    for dir <- [project, user] do
      put(dir, "report.lua", "return 'safe'")
      put(Path.dirname(dir), "x.lua", "OUTSIDE")
      put(Path.join(dir, "a"), "b.lua", "NESTED")
      put(dir, "x\n.lua", "INVALID")
    end

    opts = Keyword.put(opts, :executor, FakeJail.new(cwd, self()))
    loader = Workflows.loader(opts)

    for name <- ["../x", "a/b", "x\n"] do
      assert {:error, {:unknown_workflow, ^name, ["report"]}} = Workflows.fetch(name, opts)
      assert {:error, message} = loader.(name)
      assert message =~ "Unknown workflow #{inspect(name)}"
      assert message =~ "Available workflows: report"
      path = Path.join(project, name <> ".lua")
      expanded = Path.expand(path)
      refute_received {:fake_jail, :read, ^path}
      refute_received {:fake_jail, :read, ^expanded}
      # Discovery may stat an invalid filename directly inside the directory,
      # but it must never probe traversal or nested fetch candidates.
      if name != "x\n" do
        refute_received {:fake_jail, :stat, ^path}
        refute_received {:fake_jail, :stat, ^expanded}
      end
    end

    assert File.read!(Path.join(Path.dirname(project), "x.lua")) == "OUTSIDE"
    assert File.read!(Path.join(Path.dirname(user), "x.lua")) == "OUTSIDE"
  end

  test "save/create route through the executor, outside writes stay local", %{
    cwd: cwd,
    home: home,
    opts: opts
  } do
    opts = Keyword.put(opts, :executor, FakeJail.new(cwd, self()))
    assert {:ok, path} = Workflows.create("report", "return 1", opts)
    assert_received {:fake_jail, :write, ^path}
    assert {:ok, _, "return 1"} = Workflows.fetch("report", opts)
    assert_received {:fake_jail, :read, ^path}
    assert {:error, :eexist} = Workflows.create("report", "return 2", opts)

    assert {:error, :eexist} =
             Workflows.save(path, "return 2", Keyword.put(opts, :exclusive, true))

    assert :ok = Workflows.save(path, "return 3", opts)
    outside = Path.join(home, "workflows/user.lua")
    assert :ok = Workflows.save(outside, "return 4", Keyword.put(opts, :mkdir_p, true))
    refute_received {:fake_jail, :write, ^outside}
    assert File.read!(path) == "return 3"
    assert File.read!(outside) == "return 4"
  end

  test "create validates names and can override a user workflow", %{home: home, opts: opts} do
    for name <- ["../escape", "Upper", "bad_name", "bad--name", "", "-bad", "bad-", "bad\n"] do
      assert {:error, :invalid_name} = Workflows.create(name, "return 1", opts)
    end

    put(Path.join(home, "workflows"), "report.lua", "return 'user'")
    assert {:ok, _} = Workflows.create("report", Workflows.template("report"), opts)

    assert {:ok, %{source: :project, description: description}, script} =
             Workflows.fetch("report", opts)

    assert description =~ "report"
    assert script =~ "local profile"
    assert script =~ "tackle.await(tackle.spawn"
    assert script =~ "return result.text"
    assert {:ok, _chunk} = Lua.parse_chunk(script)
  end

  test "read caps and invalid UTF-8 produce warnings and fetch errors", %{cwd: cwd, opts: opts} do
    dir = Path.join(cwd, ".tackle/workflows")
    put(dir, "huge.lua", :binary.copy("x", 1_024 * 1_024 + 1))
    put(dir, "bytes.lua", <<255>>)
    assert %{workflows: [], warnings: [_, _]} = Workflows.discover(opts)
    assert {:error, :too_large} = Workflows.fetch("huge", opts)
    assert {:error, :invalid_utf8} = Workflows.fetch("bytes", opts)
    assert {:error, message} = Workflows.loader(opts).("huge")
    assert message =~ "data is too large"
  end

  test "planted workspace symlinks cannot read or overwrite host files", %{
    cwd: cwd,
    home: home,
    opts: opts
  } do
    secret = Path.join(home, "secret.lua")
    put(home, "secret.lua", "SECRET")
    dir = Path.join(cwd, ".tackle/workflows")
    File.mkdir_p!(dir)
    path = Path.join(dir, "leak.lua")
    File.ln_s!(secret, path)
    opts = Keyword.put(opts, :executor, FakeJail.new(cwd, self()))
    assert Workflows.discover(opts).workflows == []
    assert {:error, :enoent} = Workflows.save(path, "overwritten", opts)
    assert File.read!(secret) == "SECRET"
    File.rm!(path)
    File.rmdir!(dir)
    File.ln_s!(home, dir)
    assert {:error, :enoent} = Workflows.create("secret", "overwritten", opts)
    assert File.read!(secret) == "SECRET"
  end

  test "a user workflow directory linked into the workspace goes through the jail", %{
    root: root,
    cwd: cwd,
    home: home,
    opts: opts
  } do
    # $TACKLE_HOME/workflows -> <workspace>/shared-workflows
    shared = Path.join(cwd, "shared-workflows")
    put(shared, "report.lua", "-- Report\nreturn 1")
    File.mkdir_p!(home)
    File.ln_s!(shared, Path.join(home, "workflows"))
    opts = Keyword.put(opts, :executor, FakeJail.new(cwd, self()))

    assert {:ok, %{source: :user}, "-- Report\nreturn 1"} = Workflows.fetch("report", opts)

    # Jailed code points the workflow at a host file.
    secret = Path.join(root, "secret.lua")
    File.write!(secret, "SECRET")
    File.rm!(Path.join(shared, "report.lua"))
    File.ln_s!(secret, Path.join(shared, "report.lua"))
    user_path = Path.join(home, "workflows/report.lua")

    assert {:error, {:unknown_workflow, "report", []}} = Workflows.fetch("report", opts)
    assert {:error, :enoent} = Workflows.save(user_path, "overwritten", opts)
    assert_received {:fake_jail, :write, _path}
    assert File.read!(secret) == "SECRET"
  end

  defp put(dir, name, script) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), script)
  end
end

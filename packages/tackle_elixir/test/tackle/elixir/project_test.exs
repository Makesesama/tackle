defmodule Tackle.Elixir.ProjectTest do
  use ExUnit.Case, async: true

  alias Tackle.Elixir.Project
  alias Tackle.Executor

  @moduletag :tmp_dir

  test "elixir_file?/1 looks at the extension only" do
    for path <- ["lib/a.ex", "test/a_test.exs", "lib/page.html.heex", "lib/t.eex", "x.leex"] do
      assert Project.elixir_file?(path), path
    end

    for path <- ["README.md", "lib/a.ex.bak", "assets/app.js", "mix.lock"] do
      refute Project.elixir_file?(path), path
    end
  end

  test "compile_input?/1 keeps sources, mix.exs, and config scripts" do
    for path <- ["lib/a.ex", "lib/web/page.html.heex", "mix.exs", "config/runtime.exs"] do
      assert Project.compile_input?(path), path
    end

    for path <- [
          "test/a_test.exs",
          "priv/repo/seeds.exs",
          "deps/jason/lib/jason.ex",
          "_build/dev/lib/a.ex",
          "README.md"
        ] do
      refute Project.compile_input?(path), path
    end
  end

  test "root/2 finds the nearest mix.exs", %{tmp_dir: tmp_dir} do
    app = Path.join(tmp_dir, "apps/web")
    File.mkdir_p!(Path.join(app, "lib/web"))
    File.write!(Path.join(tmp_dir, "mix.exs"), "")
    File.write!(Path.join(app, "mix.exs"), "")

    assert Project.root(Executor.local(), Path.join(app, "lib/web/page.ex")) == {:ok, app}
    assert Project.root(Executor.local(), Path.join(tmp_dir, "lib/new/a.ex")) == {:ok, tmp_dir}
  end

  test "root/2 skips dependencies", %{tmp_dir: tmp_dir} do
    dep = Path.join(tmp_dir, "deps/jason")
    File.mkdir_p!(Path.join(dep, "lib"))
    File.write!(Path.join(tmp_dir, "mix.exs"), "")
    File.write!(Path.join(dep, "mix.exs"), "")

    assert Project.root(Executor.local(), Path.join(dep, "lib/jason.ex")) == :error
  end

  test "root/2 without a mix.exs above is an error" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "tackle_elixir_no_project_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    assert Project.root(Executor.local(), Path.join(dir, "lib/a.ex")) == :error
  end
end

defmodule Tackle.Plugins.LoaderTest do
  use ExUnit.Case, async: false

  alias Tackle.Plugins.Catalog
  alias Tackle.Plugins.Loader

  test "missing config means no enabled projects" do
    assert {:ok, catalog} =
             Loader.load(path: Path.join(System.tmp_dir!(), "missing-#{System.unique_integer()}"))

    assert catalog == %Catalog{adapters: [], tools: [], hooks: []}
  end

  test "configuration is versioned and rejects unsafe module names and relative paths" do
    root = temp_dir()

    write_config(root, [
      %{
        "path" => "relative",
        "app" => "demo",
        "adapters" => ["x;System.halt"],
        "tools" => [],
        "hooks" => []
      }
    ])

    assert {:error, {:invalid_plugin_project, _}} =
             Loader.load(path: Path.join(root, "plugins.json"))

    write_config(root, [], 2)

    assert {:error, {:invalid_plugin_config, _}} =
             Loader.load(path: Path.join(root, "plugins.json"))
  end

  test "project_paths lists enabled projects without loading them" do
    root = temp_dir()
    config = Path.join(root, "plugins.json")

    assert {:ok, []} = Loader.project_paths(path: config)

    write_config(root, [entry("/srv/plugin-a", "a", []), entry("/srv/plugin-b", "b", [])])
    assert {:ok, ["/srv/plugin-a", "/srv/plugin-b"]} = Loader.project_paths(path: config)

    write_config(root, [], 2)
    assert {:error, {:invalid_plugin_config, _}} = Loader.project_paths(path: config)
  end

  test "project_paths finds plugins.json under the environment's TACKLE_HOME" do
    root = temp_dir()
    write_config(root, [entry("/srv/plugin-a", "a", [])])

    assert {:ok, ["/srv/plugin-a"]} = Loader.project_paths(env: %{"TACKLE_HOME" => root})
  end

  test "rejects an application that two projects, or one project twice, build" do
    root = temp_dir()
    app = "loader_dup_#{System.unique_integer([:positive])}"
    first = project!(root, "first", %{"first_#{app}" => [], app => []})
    second = project!(root, "second", %{"second_#{app}" => [], app => []})
    write_config(root, [entry(first, "first_#{app}", []), entry(second, "second_#{app}", [])])

    assert {:error, {:duplicate_plugin_app, dup}} =
             Loader.load(path: Path.join(root, "plugins.json"))

    assert Atom.to_string(dup) == app

    # Two builds of one application in one project.
    twice = project!(root, "twice", %{"twice_#{app}" => [], app => []})
    File.mkdir_p!(Path.join(twice, "_build/prod/lib/copy/ebin"))

    File.cp!(
      Path.join(twice, "_build/prod/lib/#{app}/ebin/#{app}.app"),
      Path.join(twice, "_build/prod/lib/copy/ebin/#{app}.app")
    )

    write_config(root, [entry(twice, "twice_#{app}", [])])

    assert {:error, {:duplicate_plugin_app, ^dup}} =
             Loader.load(path: Path.join(root, "plugins.json"))
  end

  test "rejects a module that two projects build" do
    root = temp_dir()
    id = System.unique_integer([:positive])
    module = :"loader_dup_module_#{id}"
    first = project!(root, "first", %{"first_#{id}" => [module]})
    second = project!(root, "second", %{"second_#{id}" => [module]})
    write_config(root, [entry(first, "first_#{id}", []), entry(second, "second_#{id}", [])])

    assert {:error, {:duplicate_plugin_module, ^module}} =
             Loader.load(path: Path.join(root, "plugins.json"))

    refute :code.is_loaded(module)
  end

  test "rejects a project whose application needs one that nothing provides" do
    root = temp_dir()
    id = System.unique_integer([:positive])
    missing = :"loader_missing_#{id}"
    project = project!(root, "plugin", %{"demo_#{id}" => []}, deps: [missing])
    write_config(root, [entry(project, "demo_#{id}", [])])

    assert {:error, {:plugin_dependency_missing, {app, ^missing}}} =
             Loader.load(path: Path.join(root, "plugins.json"))

    assert Atom.to_string(app) == "demo_#{id}"
  end

  test "rejects another version of an application the host runs" do
    root = temp_dir()
    id = System.unique_integer([:positive])
    project = project!(root, "plugin", %{"demo_#{id}" => [], "tackle_lib" => []})
    write_config(root, [entry(project, "demo_#{id}", [])])
    host_vsn = Application.spec(:tackle_lib, :vsn)

    assert {:error,
            {:plugin_dependency_version_conflict, ^project, :tackle_lib, ~c"0.0.0-other",
             ^host_vsn}} = Loader.load(path: Path.join(root, "plugins.json"))
  end

  test "preflight rejects absent selected modules without adding paths" do
    root = temp_dir()
    project = Path.join(root, "plugin")
    ebin = Path.join(project, "_build/prod/lib/demo/ebin")
    File.mkdir_p!(ebin)
    File.write!(Path.join(project, "mix.exs"), "# an external Mix project\n")

    File.write!(
      Path.join(ebin, "demo.app"),
      "{application, demo, [{vsn, \"0.1.0\"}, {modules, []}, {applications, [kernel, stdlib, elixir]}]}.\n"
    )

    write_config(root, [entry(project, "demo", adapters: ["Demo.Adapter"])])

    assert {:error, {:plugin_module_not_owned_by_build, "Demo.Adapter"}} =
             Loader.load(path: Path.join(root, "plugins.json"))

    refute String.to_charlist(ebin) in :code.get_path()
  end

  test "a shared dependency's module is compared by its code, not by the runtime's file" do
    root = temp_dir()
    module = :"loader_shared_#{System.unique_integer([:positive])}"
    running = beam!(module, 1)
    rebuilt = beam!(module, 2)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    # Loaded from a binary, as from an escript's archive: no file to read.
    {:module, ^module} = :code.load_binary(module, ~c"", running)
    assert :code.which(module) == ~c""

    same = Path.join(root, "same.beam")
    File.write!(same, running)
    assert Loader.same_code?(module, same)

    other = Path.join(root, "other.beam")
    File.write!(other, rebuilt)
    refute Loader.same_code?(module, other)

    refute Loader.same_code?(module, Path.join(root, "missing.beam"))
    refute Loader.same_code?(Catalog, same)

    # A module on the code path that is not loaded yet is loaded first.
    unloaded = :"loader_unloaded_#{System.unique_integer([:positive])}"
    ebin = Path.join(root, "ebin")
    File.mkdir_p!(ebin)
    unloaded_beam = Path.join(ebin, "#{unloaded}.beam")
    File.write!(unloaded_beam, beam!(unloaded, 1))
    true = :code.add_patha(String.to_charlist(ebin))

    on_exit(fn ->
      :code.del_path(String.to_charlist(ebin))
      :code.purge(unloaded)
      :code.delete(unloaded)
    end)

    refute :code.is_loaded(unloaded)
    assert Loader.same_code?(unloaded, unloaded_beam)
    assert {:file, _path} = :code.is_loaded(unloaded)
  end

  test "a project whose build lacks its application's .app file is reported as not found" do
    root = temp_dir()
    project = Path.join(root, "plugin")
    File.mkdir_p!(Path.join(project, "_build/prod/lib/other/ebin"))
    File.write!(Path.join(project, "mix.exs"), "# an external Mix project\n")

    File.write!(
      Path.join(project, "_build/prod/lib/other/ebin/other.app"),
      "{application, other, [{vsn, \"0.1.0\"}, {modules, []}, {applications, [kernel]}]}.\n"
    )

    write_config(root, [entry(project, "demo", [])])

    assert {:error, {:plugin_project_app_not_found, ^project, "demo"}} =
             Loader.load(path: Path.join(root, "plugins.json"))
  end

  test "precompiled Mix project starts its OTP application and validates a selected tool" do
    root = temp_dir()
    project = Path.join(root, "plugin")
    app_name = "loader_fixture_#{System.unique_integer([:positive])}"
    module_name = "LoaderFixture#{System.unique_integer([:positive])}"
    app = String.to_atom(app_name)
    tool = Module.concat([module_name, "Tool"])
    File.mkdir_p!(Path.join(project, "lib"))

    File.write!(Path.join(project, "mix.exs"), """
    defmodule #{module_name}.MixProject do
      use Mix.Project
      def project, do: [app: :#{app_name}, version: "0.1.0", elixir: "~> 1.20", deps: []]
      def application, do: [extra_applications: [:logger]]
    end
    """)

    File.write!(Path.join(project, "lib/tool.ex"), """
    defmodule #{module_name}.Tool do
      def name, do: "loader_#{app_name}"
      def description, do: "test tool"
      def parameters_schema, do: %{}
      def execute(_args, _ctx), do: {:ok, "loaded"}
    end
    """)

    {output, 0} =
      System.cmd("mix", ["compile"],
        cd: project,
        env: [
          {"MIX_ENV", "prod"},
          {"MIX_HOME", Path.join(root, "mix_home")},
          {"HEX_HOME", Path.join(root, "hex_home")}
        ],
        stderr_to_stdout: true
      )

    assert output =~ "Generated #{app_name} app"
    write_config(root, [entry(project, app_name, tools: ["#{module_name}.Tool"])])

    try do
      assert {:ok, %Catalog{tools: [%{module: ^tool, source: {:project, ^project}}]}} =
               Loader.load(path: Path.join(root, "plugins.json"))

      assert app in Enum.map(Application.started_applications(), &elem(&1, 0))
      assert {:ok, "loaded"} = tool.execute(%{}, %{})
    after
      Application.stop(app)
      Application.unload(app)
      :code.del_path(String.to_charlist(Path.join(project, "_build/prod/lib/#{app_name}/ebin")))
      :code.purge(tool)
      :code.delete(tool)
    end
  end

  # A module whose `value/0` returns `value`, compiled without loading it.
  defp beam!(module, value) do
    forms = [
      {:attribute, 1, :module, module},
      {:attribute, 1, :export, [value: 0]},
      {:function, 1, :value, 0, [{:clause, 1, [], [], [{:integer, 1, value}]}]}
    ]

    {:ok, ^module, binary} = :compile.forms(forms)
    binary
  end

  # A Mix project with a production build of `apps`, each app name mapped to
  # the modules it builds (beams compiled but not loaded). An app named like
  # one the host runs gets another version.
  defp project!(root, name, apps, opts \\ []) do
    project = Path.join(root, name)
    File.mkdir_p!(project)
    File.write!(Path.join(project, "mix.exs"), "# an external Mix project\n")

    for {app, modules} <- apps do
      ebin = Path.join(project, "_build/prod/lib/#{app}/ebin")
      File.mkdir_p!(ebin)
      Enum.each(modules, &File.write!(Path.join(ebin, "#{&1}.beam"), beam!(&1, 1)))
      vsn = if Application.spec(String.to_atom(app), :vsn), do: "0.0.0-other", else: "0.1.0"
      deps = Enum.map_join([:kernel | Keyword.get(opts, :deps, [])], ", ", &Atom.to_string/1)
      module_list = Enum.map_join(modules, ", ", &Atom.to_string/1)

      File.write!(
        Path.join(ebin, "#{app}.app"),
        "{application, #{app}, [{vsn, \"#{vsn}\"}, {modules, [#{module_list}]}, " <>
          "{applications, [#{deps}]}]}.\n"
      )
    end

    project
  end

  defp entry(path, app, opts) do
    %{
      "path" => path,
      "app" => app,
      "adapters" => Keyword.get(opts, :adapters, []),
      "tools" => Keyword.get(opts, :tools, []),
      "hooks" => Keyword.get(opts, :hooks, [])
    }
  end

  defp write_config(root, projects, version \\ 1) do
    File.write!(
      Path.join(root, "plugins.json"),
      JSON.encode!(%{"version" => version, "projects" => projects})
    )
  end

  defp temp_dir do
    path = Path.join(System.tmp_dir!(), "tackle-loader-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end

defmodule Tackle.Plugins.LoaderTest do
  use ExUnit.Case, async: false

  alias Tackle.Plugins.Loader

  test "missing config means no enabled projects" do
    assert {:ok, %{adapters: [], tools: [], hooks: []}} =
             Loader.load(path: Path.join(System.tmp_dir!(), "missing-#{System.unique_integer()}"))
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
      assert {:ok, %{tools: [%{module: ^tool, source: {:project, ^project}}]}} =
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

defmodule Tackle.Elixir.Test.Projects do
  @moduledoc false

  @doc "Creates a minimal Mix project with `files` (relative path => source)."
  def new(files \\ %{}) do
    root =
      Path.join(System.tmp_dir!(), "tackle-elixir-project-#{System.unique_integer([:positive])}")

    app = "probe#{System.unique_integer([:positive])}"

    File.mkdir_p!(Path.join(root, "lib"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule #{Macro.camelize(app)}.MixProject do
      use Mix.Project
      def project, do: [app: :#{app}, version: "0.1.0"]
    end
    """)

    for {path, source} <- files, do: write(root, path, source)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  def write(root, path, source) do
    path = Path.join(root, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
  end
end

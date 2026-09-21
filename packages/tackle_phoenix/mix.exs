defmodule Tackle.Phoenix.MixProject do
  use Mix.Project

  def project do
    [
      app: :tackle_phoenix,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # The framework-free agent core (Tackle.Lib.*) this layer drives.
      {:tackle_lib, path: "../tackle_lib"},
      {:tackle_runtime, path: "../tackle_runtime"},
      # Phoenix runtime + LiveView UI glue (Runner/EventReducer/Chat/PubSub).
      {:phoenix_live_view, ">= 1.1.33 and < 1.3.0"},
      {:phoenix_pubsub, "~> 2.1"}
    ]
  end
end

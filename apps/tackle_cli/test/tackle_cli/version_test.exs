defmodule Tackle.CLI.VersionTest do
  use ExUnit.Case, async: true

  # The application version is what Burrito extracts its release under and what
  # `tackle --version` reports: it has to satisfy Elixir's semver parser (Mix
  # refuses to write a `.app` file otherwise) and the wrapper's, and it has to
  # build on the release version in `VERSION`, whatever stamp the build adds.
  # `TACKLE_VERSION` replaces the whole string, which is how a release build pins
  # an exact version.
  test "is a stamped release version" do
    version = Mix.Project.config()[:version]
    base = System.get_env("TACKLE_VERSION") || release_version()

    assert version =~ ~r/\A#{Regex.escape(base)}(?:-dev\.\d+\+g[0-9a-f]+(?:\.dirty)?)?\z/
    assert {:ok, _} = Version.parse(version)
  end

  defp release_version do
    Path.join(__DIR__, "../../VERSION") |> File.read!() |> String.trim()
  end
end

defmodule Tackle.CLI.ReleaseTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.Release

  # The load paths of the two bundled NIFs, in the shape Rustler exposes them.
  # Tests pass them explicitly so a release-config change cannot quietly turn a
  # verification test into a no-op.
  defp source_libraries do
    [
      {:ex_ratatui, fn -> {:ex_ratatui, "priv/native/ex_ratatui"} end},
      {:tackle_cli, fn -> {:tackle_cli, "priv/native/tackle"} end}
    ]
  end

  defp runtime_libraries do
    [
      {:ex_ratatui, &ExRatatui.Native.load_from/0},
      {:tackle_cli, &Release.tackle_load_from/0}
    ]
  end

  test "Linux release verification rejects a glibc native library" do
    with_env("BURRITO_TARGET", "linux_aarch64", fn ->
      release = release_fixture("libc.so.6")

      assert_raise Mix.Error, ~r/linked against glibc/, fn ->
        Release.verify_linux_nifs(release, source_libraries())
      end
    end)
  end

  test "Linux release verification rejects the shared unwinder" do
    with_env("BURRITO_TARGET", "linux_aarch64", fn ->
      release = release_fixture("libgcc_s.so.1")

      assert_raise Mix.Error, ~r/needs libgcc_s.so.1/, fn ->
        Release.verify_linux_nifs(release, source_libraries())
      end
    end)
  end

  test "Linux release verification accepts musl native libraries" do
    with_env("BURRITO_TARGET", "linux_aarch64", fn ->
      release = release_fixture("libc.so", runtime_libraries())

      assert Release.verify_linux_nifs(release) == release
    end)
  end

  test "Linux release verification only checks the NIF the build loads" do
    with_env("BURRITO_TARGET", "linux_aarch64", fn ->
      release = release_fixture("libc.so")

      # `priv/native` accumulates the artifacts of every version and ABI ever
      # resolved there and all of them ride into the release, so a stale glibc
      # sibling must not fail a correct build.
      write_nif(release, "ex_ratatui", "priv/native/ex_ratatui-glibc.so", "libc.so.6")

      assert Release.verify_linux_nifs(release, source_libraries()) == release
    end)
  end

  test "Linux release verification accepts ExRatatui's precompiled musl NIF" do
    with_env("BURRITO_TARGET", "linux_aarch64", fn ->
      precompiled = "priv/native/libex_ratatui-v0.15.0-nif-2.17-aarch64-unknown-linux-musl"

      libraries = [
        {:ex_ratatui, fn -> {:ex_ratatui, precompiled} end},
        {:tackle_cli, fn -> {:tackle_cli, "priv/native/tackle"} end}
      ]

      release = release_fixture("libc.so", libraries)

      assert Release.verify_linux_nifs(release, libraries) == release
    end)
  end

  test "Linux release verification fails when the assembled NIF is missing" do
    with_env("BURRITO_TARGET", "linux_aarch64", fn ->
      release = %Mix.Release{path: tmp_dir()}

      assert_raise Mix.Error, ~r/no ex_ratatui NIF found/, fn ->
        Release.verify_linux_nifs(release)
      end
    end)
  end

  test "verification is a no-op for non-Linux targets" do
    with_env("BURRITO_TARGET", "macos", fn ->
      release = %Mix.Release{path: "/does/not/exist"}

      assert Release.verify_linux_nifs(release) == release
    end)
  end

  test "verification is a no-op without a Burrito target" do
    with_env("BURRITO_TARGET", nil, fn ->
      release = %Mix.Release{path: "/does/not/exist"}

      assert Release.verify_linux_nifs(release) == release
    end)
  end

  defp release_fixture(contents, libraries \\ source_libraries()) do
    release = %Mix.Release{path: tmp_dir()}

    for {_app, load_from} <- libraries do
      {app, relative_path} = load_from.()
      write_nif(release, app, "#{relative_path}.so", contents)
    end

    release
  end

  defp write_nif(%Mix.Release{path: root}, app, relative_path, contents) do
    path = Path.join(root, "lib/#{app}-0.1.0/#{relative_path}")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp tmp_dir do
    path =
      Path.join(System.tmp_dir!(), "tackle-cli-release-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp with_env(name, value, fun) do
    previous = System.get_env(name)
    if value, do: System.put_env(name, value), else: System.delete_env(name)

    try do
      fun.()
    after
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end
  end
end

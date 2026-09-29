defmodule Tackle.CLI.Release do
  @moduledoc false

  @native_libraries [
    {:ex_ratatui, &ExRatatui.Native.load_from/0},
    {:tackle_cli, &__MODULE__.tackle_load_from/0}
  ]

  # Bytes that mark an ELF as linked against glibc, and the shared unwinder
  # Burrito's musl runtime does not ship. A correct musl NIF references neither:
  # its only dynamic dependency is musl's own `libc.so`.
  @glibc_markers ["libc.so.6", "GLIBC_"]
  @unwinder_marker "libgcc_s.so.1"

  @doc false
  @spec standalone_boot(Mix.Release.t()) :: Mix.Release.t()
  def standalone_boot(release) do
    path = Path.join([release.path, "releases", release.version, "start"])
    {:ok, [{:script, id, instructions}]} = :file.consult(path <> ".script")

    # Run after application startup but before boot returns to Burrito's
    # `-s elixir start_cli`. Do not block an application's supervisor startup.
    {startup, [started]} = Enum.split(instructions, -1)
    {:progress, :started} = started
    script = {:script, id, startup ++ [{:apply, {Tackle.CLI.Standalone, :boot, []}}, started]}
    File.write!(path <> ".script", :io_lib.format(~c"~tp.~n", [script]))
    File.write!(path <> ".boot", :erlang.term_to_binary(script))
    release
  end

  @spec verify_linux_nifs(Mix.Release.t()) :: Mix.Release.t()
  def verify_linux_nifs(release), do: verify_linux_nifs(release, @native_libraries)

  @doc false
  @spec verify_linux_nifs(Mix.Release.t(), [{atom(), (-> {atom(), String.t()})}]) ::
          Mix.Release.t()
  def verify_linux_nifs(release, native_libraries) do
    if linux?(System.get_env("BURRITO_TARGET")) do
      Enum.each(native_libraries, &verify_nif!(release, &1))
    end

    release
  end

  @doc false
  def tackle_load_from, do: {:tackle_cli, "priv/native/tackle"}

  defp linux?(target), do: is_binary(target) and String.starts_with?(target, "linux")

  defp verify_nif!(release, {app, load_from}) do
    {^app, relative_path} = load_from.()

    release.path
    |> Path.join("lib/#{app}-*/#{relative_path}.so")
    |> Path.wildcard()
    |> case do
      [] ->
        Mix.raise("no #{app} NIF found in the assembled release")

      paths ->
        Enum.each(paths, &verify_musl!/1)
    end
  end

  defp verify_musl!(path) do
    bytes = File.read!(path)

    if Enum.any?(@glibc_markers, &String.contains?(bytes, &1)) do
      Mix.raise("""
      #{Path.relative_to_cwd(path)} is linked against glibc, but Burrito's Linux runtime uses musl.

      Build the Linux release with the musl NIFs as documented in README.md.
      """)
    end

    if String.contains?(bytes, @unwinder_marker) do
      Mix.raise("""
      #{Path.relative_to_cwd(path)} needs #{@unwinder_marker}, which Burrito's Linux runtime
      does not ship, so the wrapped binary would fail at NIF load.

      Build the Linux release with the musl toolchain the Nix development shell
      provides; see README.md.
      """)
    end
  end
end

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

    verify_source_build!(app, relative_path)

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

  # A precompiled ExRatatui NIF is always the wrong artifact here, even the musl
  # one: the pinned fork adds `Markdown.measure_height/2`, and the published
  # artifacts do not export that NIF. It would pass the musl check below and
  # then fail on the first Markdown measurement, so reject it at build time.
  defp verify_source_build!(:ex_ratatui, relative_path) do
    if String.starts_with?(Path.basename(relative_path), "libex_ratatui-") do
      Mix.raise("""
      the Linux release would bundle ExRatatui's precompiled NIF (#{relative_path}), \
      which does not export this frontend's pinned fork API.

      Keep `config :rustler_precompiled, :force_build, ex_ratatui: true` and release \
      from the Nix development shell so both NIFs are compiled for musl instead.
      """)
    end
  end

  defp verify_source_build!(_app, _relative_path), do: :ok

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

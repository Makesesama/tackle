import Config

# Burrito boots the Linux payload on a musl ERTS, so every Rust NIF the release
# bundles has to be a musl build for that target's CPU. Both NIFs are compiled
# from source: the pinned ExRatatui fork adds `Markdown.measure_height/2`, which
# the published precompiled artifacts do not export. Rustler bakes the target
# triple into the compiled module, so the triple has to be known while the
# crates are compiled, and the Burrito target being built is the only thing that
# names it.
#
# The toolchain is the one the Nix development shell provides, through three
# variables:
#
#   * TACKLE_MUSL_CC    - C compiler for the same musl triple: the crates'
#                         `CC_<target>`, used to find the static unwinder they
#                         link instead of libgcc_s, and the cargo linker.
#   * TACKLE_MUSL_CARGO - cargo that can target musl (nixpkgs' cargo cannot,
#                         it has no musl standard library).
#   * TACKLE_MUSL_RUSTC - the matching rustc, so that cargo looks up the musl
#                         standard library instead of the host one.
linux_musl_targets = %{
  "linux_aarch64" => "aarch64-unknown-linux-musl",
  "linux_x86_64" => "x86_64-unknown-linux-musl"
}

if triple = linux_musl_targets[System.get_env("BURRITO_TARGET")] do
  musl_cc =
    System.get_env("TACKLE_MUSL_CC") ||
      raise """
      BURRITO_TARGET=#{System.get_env("BURRITO_TARGET")} packages a musl payload, but
      TACKLE_MUSL_CC is not set.

      Run the release from the Nix development shell, or point TACKLE_MUSL_CC at a
      C compiler that targets #{triple}. See the "Single-file release" section of
      README.md.
      """

  rustc = System.get_env("TACKLE_MUSL_RUSTC")
  underscored = String.replace(triple, "-", "_")

  nif_env =
    [
      {"CC_#{underscored}", musl_cc},
      {"CARGO_TARGET_#{String.upcase(underscored)}_LINKER", musl_cc}
    ] ++ if(rustc, do: [{"RUSTC", rustc}], else: [])

  nif_opts =
    [target: triple, env: nif_env] ++
      case System.get_env("TACKLE_MUSL_CARGO") do
        nil -> []
        cargo -> [cargo: {:bin, cargo}]
      end

  config :ex_ratatui, ExRatatui.Native, nif_opts
  config :tackle_cli, Tackle.CLI.Native, nif_opts
end

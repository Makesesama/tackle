{
  lib,
  beamPackages,
}:

# The dependency-free exec-server package, compiled on its own so the jail
# carries no harness, provider, or third-party code.
beamPackages.buildMix {
  name = "tackle_exec";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../../packages/tackle_exec;
    fileset = lib.fileset.unions [
      ../../packages/tackle_exec/mix.exs
      ../../packages/tackle_exec/lib
    ];
  };
}

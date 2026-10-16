# NixOS VM test for services.tackle-web: the release starts as its own user
# against a local PostgreSQL over peer authentication, runs its migrations,
# and answers its health check.
#
#   nix build .#checks.x86_64-linux.tackle-web-vm
#
# The secrets are fixed test values; a real host keeps them in a file outside
# the store.
self: {
  name = "tackle-web";

  nodes.machine = {
    imports = [ self.nixosModules.tackle-web ];

    virtualisation.memorySize = 2048;

    environment.etc."tackle-web.env".text = ''
      SECRET_KEY_BASE=vm-test-secret-key-base-vm-test-secret-key-base-vm-test-secret-key-base
      TACKLE_WEB_CLOAK_KEY=AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
    '';

    services.tackle-web = {
      enable = true;
      environmentFile = "/etc/tackle-web.env";
    };
  };

  testScript =
    { nodes, ... }:
    let
      package = nodes.machine.services.tackle-web.package;
    in
    ''
      machine.wait_for_unit("tackle-web.service")
      machine.wait_for_open_port(4000)

      with subtest("health check answers once the database is migrated"):
          machine.succeed("curl -sf http://127.0.0.1:4000/health | grep -F '\"status\":\"ok\"'")
          # Every migration the release ships is applied.
          shipped = machine.succeed(
              "ls ${package}/lib/tackle_web-*/priv/repo/migrations/*.exs | wc -l"
          ).strip()
          machine.succeed(
              "runuser -u postgres -- psql -d tackle-web -tAc "
              f"'select count(*) from schema_migrations' | grep -x {shipped}"
          )
          machine.succeed("runuser -u postgres -- psql -d tackle-web -tAc 'select 1 from oban_jobs limit 1'")

      with subtest("runs as its own user, with HOME outside the state directory"):
          machine.succeed("systemctl show tackle-web -p User | grep -x User=tackle-web")
          machine.succeed("test \"$(stat -c %U /var/lib/tackle-web)\" = tackle-web")
          machine.succeed("test \"$(stat -c %U /var/lib/tackle-web-home)\" = tackle-web")
          pid = machine.succeed("systemctl show tackle-web -p MainPID --value").strip()
          machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ | grep -x HOME=/var/lib/tackle-web-home")

      with subtest("listens on the configured address only, with no Erlang distribution"):
          # The BEAM's only listening socket is the HTTP port: no distribution
          # listener on any port, and no epmd.
          machine.succeed(
              "test \"$(ss -ltnpH | grep -F beam.smp | awk '{print $4}')\" = 127.0.0.1:4000"
          )
          machine.fail("ss -ltn | grep -q ':4369 '")

      with subtest("restarts with the migrations already applied"):
          machine.succeed("systemctl restart tackle-web")
          machine.wait_for_unit("tackle-web.service")
          machine.wait_for_open_port(4000)
          machine.succeed("curl -sf http://127.0.0.1:4000/health")
    '';
}

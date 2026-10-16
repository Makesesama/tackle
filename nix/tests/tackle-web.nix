# NixOS VM test for services.tackle-web: the release starts as its own user
# against a local PostgreSQL over peer authentication, runs its migrations,
# answers its health check, stores a GitHub App through
# `tackle-web-release`, and accepts that App's signed webhooks.
#
#   nix build .#checks.x86_64-linux.tackle-web-vm
#
# The secrets are fixed test values; a real host keeps them in a file outside
# the store.
self: {
  name = "tackle-web";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.tackle-web ];

      virtualisation.memorySize = 2048;

      # To generate the test App's key and sign the test delivery.
      environment.systemPackages = [ pkgs.openssl ];

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

      def psql(query):
          return f"runuser -u postgres -- psql -d tackle-web -tAc \"{query}\""

      with subtest("health check answers once the database is migrated"):
          machine.succeed("curl -sf http://127.0.0.1:4000/health | grep -F '\"status\":\"ok\"'")
          # Every migration the release ships is applied.
          shipped = machine.succeed(
              "ls ${package}/lib/tackle_web-*/priv/repo/migrations/*.exs | wc -l"
          ).strip()
          machine.succeed(psql("select count(*) from schema_migrations") + f" | grep -x {shipped}")
          machine.succeed(psql("select 1 from oban_jobs limit 1"))

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

      with subtest("stores a GitHub App through the release command"):
          machine.succeed(
              "install -d -m 0755 /tmp/app",
              "openssl genrsa -traditional -out /tmp/app/key.pem 2048",
              "printf 'vm-webhook-secret\\n' > /tmp/app/webhook",
              "chmod 0644 /tmp/app/key.pem /tmp/app/webhook",
          )
          # Only root may run it: it starts a unit as the service user.
          status, output = machine.execute(
              "runuser -u nobody -- tackle-web-release eval 'IO.puts(:hi)' 2>&1"
          )
          assert status != 0 and "run as root" in output, output
          machine.succeed(
              "TACKLE_WEB_GITHUB_APP_ID=4242 "
              "TACKLE_WEB_GITHUB_PRIVATE_KEY_FILE=/tmp/app/key.pem "
              "TACKLE_WEB_GITHUB_WEBHOOK_SECRET_FILE=/tmp/app/webhook "
              "tackle-web-release eval 'Tackle.Web.Release.configure_github_app()' "
              "| grep -F 'Stored the GitHub App 4242.'"
          )
          # The secret is stored, encrypted.
          machine.succeed(psql("select app_id from forge_apps") + " | grep -x 4242")
          machine.succeed(
              psql("select length(encrypted_webhook_secret) > 0 from forge_apps") + " | grep -x t"
          )
          machine.fail(
              psql("select encode(encrypted_webhook_secret, 'escape') from forge_apps")
              + " | grep -F vm-webhook-secret"
          )

      with subtest("accepts the App's signed webhooks and rejects others"):
          machine.succeed(
              "printf '%s' "
              "'{\"action\":\"created\",\"installation\":{\"id\":77,\"account\":{\"login\":\"acme\"}},"
              "\"repositories\":[{\"id\":5,\"name\":\"widgets\",\"full_name\":\"acme/widgets\"}]}' "
              "> /tmp/app/body.json"
          )
          signature = machine.succeed(
              "openssl dgst -sha256 -hmac vm-webhook-secret /tmp/app/body.json | cut -d' ' -f2"
          ).strip()

          def deliver(signature):
              return machine.succeed(
                  "curl -s -o /dev/null -w '%{http_code}' -X POST "
                  "-H 'content-type: application/json' -H 'x-github-event: installation' "
                  f"-H 'x-hub-signature-256: sha256={signature}' "
                  "--data-binary @/tmp/app/body.json http://127.0.0.1:4000/webhooks/github"
              ).strip()

          assert deliver("0" * 64) == "401"
          assert deliver(signature) == "200"
          machine.succeed(
              psql(
                  "select r.name from repositories r join installations i "
                  "on r.installation_id = i.id where i.external_id = '77'"
              )
              + " | grep -x widgets"
          )

      with subtest("restarts with the migrations already applied"):
          machine.succeed("systemctl restart tackle-web")
          machine.wait_for_unit("tackle-web.service")
          machine.wait_for_open_port(4000)
          machine.succeed("curl -sf http://127.0.0.1:4000/health")
    '';
}

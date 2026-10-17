# NixOS VM test for services.tackle-web: the release starts as its own user
# against a local PostgreSQL over peer authentication, runs its migrations,
# answers its health check, offers browser setup with a logged setup token and
# keeps the admin pages behind sign-in, stores a GitHub App through
# `tackle-web-release`, and accepts that App's signed webhooks. It also runs
# the review jail's launcher as the service user, with a probe inside instead
# of the exec-server, to check what jailed code can reach on a real host.
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

      # To generate the test App's key and sign the test delivery; and the
      # review jail's launcher around a probe, `tackle-review-jail-probe`,
      # which exits nonzero if jailed code can reach any of these.
      environment.systemPackages = [
        pkgs.openssl
        (self.packages.${pkgs.stdenv.hostPlatform.system}.tackle-review-jail.withEntry (
          pkgs.writeShellApplication {
            name = "review-jail-probe";
            text = ''
              # The host's database socket, secrets, and processes are out of reach.
              test ! -e /run/postgresql
              test ! -e /var/lib/postgresql
              test ! -e /etc/tackle-web.env
              test ! -e "$HOME/host-only"
              for proc in /proc/[0-9]*; do
                case "$(cat "$proc/comm" 2>/dev/null)" in
                  beam.smp | postgres) exit 1 ;;
                esac
              done
              # Its resource limits (nix/packages/review-jail.nix).
              test "$(cat /proc/self/oom_score_adj)" = 1000
              test "$(ulimit -H -f)" = 262144
              for dir in /tmp "$HOME" /dev/shm; do
                test "$(df -B1 --output=size "$dir" | tail -n 1 | tr -d ' ')" = 268435456
              done
              echo "review jail probe: OK"
            '';
          }
        ))
      ];

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
      reviewLauncher = nodes.machine.systemd.services.tackle-web.environment.TACKLE_WEB_REVIEW_JAIL;
      checkoutPath = nodes.machine.systemd.services.tackle-web.environment.PATH;
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

      with subtest("offers browser setup with a logged token, and keeps admin pages behind sign-in"):
          machine.succeed("curl -sf http://127.0.0.1:4000/ | grep -F 'set up tackle'")
          machine.succeed("curl -sf http://127.0.0.1:4000/setup | grep -F 'Unlock setup'")
          machine.wait_until_succeeds("journalctl -u tackle-web | grep -F 'setup token'")
          for path in ["/admin", "/codex-login"]:
              status = machine.succeed(
                  f"curl -s -o /dev/null -w '%{{http_code}}' http://127.0.0.1:4000{path}"
              ).strip()
              assert status == "302", f"{path}: {status}"
          # The LiveView client is served from its package inside the release.
          machine.succeed(
              "curl -sf -o /dev/null http://127.0.0.1:4000/vendor/phoenix_live_view/phoenix_live_view.min.js"
          )

      with subtest("runs as its own user, with HOME outside the state directory"):
          machine.succeed("systemctl show tackle-web -p User | grep -x User=tackle-web")
          machine.succeed("test \"$(stat -c %U /var/lib/tackle-web)\" = tackle-web")
          machine.succeed("test \"$(stat -c %U /var/lib/tackle-web-home)\" = tackle-web")
          pid = machine.succeed("systemctl show tackle-web -p MainPID --value").strip()
          machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ | grep -x HOME=/var/lib/tackle-web-home")

      with subtest("configures the review launcher and permits user namespaces"):
          machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ | grep -x TACKLE_WEB_REVIEW_JAIL=${reviewLauncher}")
          machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ | grep -x TACKLE_WEB_STATE_DIR=/var/lib/tackle-web")
          machine.succeed("systemctl show tackle-web -p RestrictNamespaces --value | grep -E '(^no$|(^| )user( |$))'")
          machine.succeed("test -x ${reviewLauncher}")

      with subtest("bounds the service's memory and tasks; an OOM kill does not stop it"):
          machine.succeed("systemctl show tackle-web -p MemoryMax --value | grep -x 4294967296")
          machine.succeed("systemctl show tackle-web -p TasksMax --value | grep -x 2048")
          machine.succeed("systemctl show tackle-web -p OOMPolicy --value | grep -x continue")

      with subtest("the review jail hides the database socket and host processes"):
          # Peer authentication admits any process of the service user that
          # reaches this socket, so it must not be visible in the jail.
          machine.succeed("runuser -u tackle-web -- test -S /run/postgresql/.s.PGSQL.5432")
          machine.succeed("install -d -o tackle-web -g tackle-web -m 0750 /var/lib/tackle-web/vm-probe")
          # The jail's home is private: this host file must not show through.
          machine.succeed("runuser -u tackle-web -- touch /var/lib/tackle-web-home/host-only")
          machine.succeed(
              "cd /var/lib/tackle-web/vm-probe && "
              "runuser -u tackle-web -- env HOME=/var/lib/tackle-web-home "
              "tackle-review-jail-probe /dev/null | grep -Fx 'review jail probe: OK'"
          )

      with subtest("host checkout executables and system TLS trust are available"):
          machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ | grep -Fx 'PATH=${checkoutPath}'")
          machine.succeed("env -i PATH=${checkoutPath} bash -c 'command -v git; command -v setsid; command -v flock'")
          machine.succeed("env -i PATH=${checkoutPath} bash -c 'git --version && setsid --version && flock --version'")
          # Checkout.Git ignores caller CA overrides and Git system config,
          # explicitly using this NixOS system trust path instead.
          machine.succeed("test -s /etc/ssl/certs/ca-certificates.crt")

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

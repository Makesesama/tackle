# tackle_web

**Status: phase 1 of [`docs/TACKLE_WEB_PLAN.md`](../../docs/TACKLE_WEB_PLAN.md).**
A web app that will review pull requests with
[`tackle_review`](../../packages/tackle_review/README.md) and post the
findings to the forge. So far it is only the skeleton: a Phoenix endpoint
with a health check, the PostgreSQL repository, the Cloak vault, Oban, and
the empty Ash domains, packaged for Nix with a NixOS module. It cannot
review anything yet; the plan lists what each phase adds.

OTP application `:tackle_web`, namespace `Tackle.Web.*`. It depends on the
packages (`tackle_lib`, `tackle_runtime`, `tackle_review`, `tackle_tools`,
`tackle_exec`, and the OpenRouter and Codex adapters), not on the harness
package `packages/tackle`.

## Development

Development and tests use a PostgreSQL server (16 or later) on
`localhost:5432` as `postgres`/`postgres`, and create the `tackle_web_dev`
and `tackle_web_test` databases themselves. The standard `PGHOST`,
`PGPORT`, `PGUSER`, and `PGPASSWORD` variables point them elsewhere. From
this directory, inside `nix develop`:

```sh
mix setup                   # deps.get, create the database, migrate
mix phx.server              # http://127.0.0.1:4000/health
mix test                    # creates and migrates the test database first
```

Without such a server, `scripts/db.sh` runs a throwaway cluster from the
dev shell's PostgreSQL in `.postgres/`, on a Unix socket only:

```sh
bash scripts/db.sh start
export TACKLE_WEB_PGHOST=$PWD/.postgres   # as the script prints
bash scripts/db.sh stop
```

If `idna` or another rebar3 dependency fails to build, set
`MIX_REBAR3=$(which rebar3)`.

Checks, as for the other projects:

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
```

Migrations: `mix ash.codegen <name>` generates them from the Ash resources;
review every generated migration before committing it.

## Configuration in production

`config/runtime.exs` reads the environment:

| Variable | Default | Meaning |
|---|---|---|
| `SECRET_KEY_BASE` | required | Phoenix's signing secret (`mix phx.gen.secret`) |
| `TACKLE_WEB_CLOAK_KEY` | required | base64 of a random 32-byte key that encrypts secrets in the database |
| `TACKLE_WEB_CLOAK_RETIRED_KEYS` | none | comma-separated earlier keys, accepted for decryption only (key rotation) |
| `DATABASE_URL` | unset | an Ecto URL; when unset, the Unix socket settings below are used |
| `TACKLE_WEB_DATABASE_SOCKET_DIR` | `/run/postgresql` | socket directory of a local server (peer authentication) |
| `TACKLE_WEB_DATABASE` | `tackle_web` | database name |
| `TACKLE_WEB_DATABASE_USER` | `tackle-web` | database user, the service's system user for peer authentication |
| `POOL_SIZE` | `10` | database connections |
| `LISTEN_ADDRESS` | `127.0.0.1` | IP address to listen on |
| `PORT` | `4000` | port to listen on |
| `TACKLE_WEB_URL` | `http://localhost:4000` | the public URL, as the forge and browsers reach the app |

Generate a Cloak key with `head -c 32 /dev/urandom | base64`. Losing it
loses every stored secret (forge app secrets, provider credentials); they
have to be entered again. To rotate it, set the new key, move the old one to
`TACKLE_WEB_CLOAK_RETIRED_KEYS`, and re-encrypt before dropping it (see
`Tackle.Web.Vault`).

Forge and provider secrets are not configuration: they are entered in the
app and stored encrypted.

Run migrations in a release with
`bin/tackle_web eval "Tackle.Web.Release.migrate()"`.

## Nix package and NixOS module

`nix build .#tackle-web` builds the release (`nix/packages/tackle-web.nix`)
from `nix/tackle-web-deps.nix`. After changing dependencies, regenerate that
file and check that the package still builds:

```sh
mix deps.nix                     # in this directory
nix fmt -- ../../nix/tackle-web-deps.nix
nix build ../..#tackle-web
```

The dependencies are compiled without the app's `config/`, except for
`config/ash.exs`, which every dependency is compiled with: Ash reads those
settings at compile time, and a release refuses to boot when they differ
from the app's. Keep Ash's settings there and nothing else.

The flake's `nixosModules.tackle-web` runs it:

```nix
{
  imports = [ tackle.nixosModules.tackle-web ];
  services.tackle-web = {
    enable = true;
    url = "https://review.example.com";
    # SECRET_KEY_BASE=... and TACKLE_WEB_CLOAK_KEY=..., outside the store
    environmentFile = "/run/secrets/tackle-web.env";
  };
}
```

It runs the release as the `tackle-web` system user, creates a local
PostgreSQL database `tackle-web` reached over the Unix socket with peer
authentication (`database.createLocally`, on by default; otherwise put a
`DATABASE_URL` in the environment file), runs migrations before every
start, and listens on `127.0.0.1:4000` (`listenAddress`, `port`). TLS and
making the app reachable for forge webhooks are up to you, for example a
reverse proxy in front of it. Erlang distribution is off. The user's home
(`homeDir`, `/var/lib/tackle-web-home`) is kept apart from the state
directory (`stateDir`, `/var/lib/tackle-web`), which later phases need for
the review jail.

The VM test starts the service with PostgreSQL and checks its health
(needs KVM): `nix build .#checks.x86_64-linux.tackle-web-vm`.

## JSON

Our code uses Elixir's standard `JSON` module, as everywhere in this
repository; Phoenix is configured to use it too. Ash, Oban, Postgrex, and
Cloak pull in Jason as a transitive dependency, which is accepted; do not
add it to `mix.exs` or call it.

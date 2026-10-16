# tackle_web

**Status: phase 1a of [`docs/TACKLE_WEB_PLAN.md`](../../docs/TACKLE_WEB_PLAN.md).**
A web app that will review pull requests with
[`tackle_review`](../../packages/tackle_review/README.md) and post the
findings to the forge. So far it is only the skeleton: a Phoenix endpoint
with a health check, the PostgreSQL repository, the Cloak vault, Oban, and
the empty Ash domains. It cannot review anything yet; the plan lists what
each phase adds.

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

## JSON

Our code uses Elixir's standard `JSON` module, as everywhere in this
repository; Phoenix is configured to use it too. Ash, Oban, Postgrex, and
Cloak pull in Jason as a transitive dependency, which is accepted; do not
add it to `mix.exs` or call it.

# tackle_web

**Status: phases 1 and 2 of [`docs/TACKLE_WEB_PLAN.md`](../../docs/TACKLE_WEB_PLAN.md).**
A web app that will review pull requests with
[`tackle_review`](../../packages/tackle_review/README.md) and post the
findings to the forge. So far it receives GitHub webhooks: it keeps track
of the GitHub App's installations and repositories, and turns pull request
events and `/tackle review` commands into review requests according to
each repository's settings. Nothing runs those requests yet (phase 4); the
plan lists what each phase adds.

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

`tackle-web-release` (installed by the module) runs the release's
commands beside the running service, as a transient systemd unit with the
service's user, environment, and `environmentFile`; run it as root. It
passes on the caller's `TACKLE_WEB_GITHUB_*` variables and nothing else:

```sh
sudo tackle-web-release eval "Tackle.Web.Release.migrate()"
```

The VM test starts the service with PostgreSQL, checks its health, stores
a GitHub App through `tackle-web-release`, and delivers a signed webhook
(needs KVM): `nix build .#checks.x86_64-linux.tackle-web-vm`.

## Connecting a GitHub App

Reviews run as a GitHub App that you create for your organisation
(Settings → Developer settings → GitHub Apps → New GitHub App):

- **Webhook URL:** `<TACKLE_WEB_URL>/webhooks/github`, with a random
  webhook secret (`openssl rand -hex 32`).
- **Repository permissions:** Metadata read, Contents read, Pull requests
  read and write, Issues read (only to receive comments on pull requests).
- **Organisation permissions:** Members read (for sign-in, later).
- **Events:** Pull request, Issue comment. Installation events are always
  delivered.

Generate a private key for the App, then store the App in tackle_web.
Secrets are read from files, so they stay out of the process list and
shell history, and are stored encrypted. The command runs as the
`tackle-web` user, which must be able to read the files; remove them
afterwards:

```sh
sudo install -d -m 0700 -o tackle-web /var/lib/tackle-web-home/setup
sudo install -m 0400 -o tackle-web app.private-key.pem webhook-secret \
  /var/lib/tackle-web-home/setup/
sudo TACKLE_WEB_GITHUB_APP_ID=123456 \
  TACKLE_WEB_GITHUB_PRIVATE_KEY_FILE=/var/lib/tackle-web-home/setup/app.private-key.pem \
  TACKLE_WEB_GITHUB_WEBHOOK_SECRET_FILE=/var/lib/tackle-web-home/setup/webhook-secret \
  tackle-web-release eval "Tackle.Web.Release.configure_github_app()"
sudo rm -r /var/lib/tackle-web-home/setup
```

`TACKLE_WEB_GITHUB_CLIENT_ID` and `TACKLE_WEB_GITHUB_CLIENT_SECRET_FILE`
(for sign-in, later) are optional. Running the command again replaces the
stored App. Until it has run, webhooks are answered with 503.

Then install the App on the organisation. Its repositories are recorded as
the installation and repository events arrive, disabled by default. Until
the admin pages exist (phase 6), repository settings are changed in the
database or with `Tackle.Web.Forges.Repository.configure/2`, and the
installation's defaults with `Tackle.Web.Forges.Installation.set_defaults/2`.

What happens with a pull request (`Tackle.Web.Triggers`):

- `/tackle review [quiet|default|assertive]` in a comment, from someone with
  write access, requests a review of the current head in any enabled
  repository.
- Repositories with `auto_review: :on_open` request one when a pull
  request is opened, reopened, or ready for review; `:on_open_and_push`
  also for every new head. Drafts and forks only with `auto_review_drafts`
  and `auto_review_forks`.
- A head is requested once. A command asks again after a failure, or for a
  posted review with another profile. A new head skips the pending requests
  for older ones; closing a pull request skips its pending requests.

## JSON

Our code uses Elixir's standard `JSON` module, as everywhere in this
repository; Phoenix is configured to use it too. Ash, Oban, Postgrex, and
Cloak pull in Jason as a transitive dependency, which is accepted; do not
add it to `mix.exs` or call it.

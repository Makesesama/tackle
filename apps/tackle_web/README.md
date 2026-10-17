# tackle_web

**Status: phases 1–9 (7: ownership and access, 8: user pages, 9: feedback)
and 6b (web-only setup) of
[`docs/TACKLE_WEB_PLAN.md`](../../docs/TACKLE_WEB_PLAN.md).**
A web app that will review pull requests with
[`tackle_review`](../../packages/tackle_review/README.md) and post the
findings to the forge. So far it receives GitHub webhooks: it keeps track
of the GitHub App's installations and repositories, and turns pull request
events and `/tackle review` commands into review requests according to
each repository's settings. It also stores model providers and encrypted
credentials, resolves review defaults, and has an ephemeral agent backend tested
with whole scripted reviews. Setup is done in the browser: it registers and
installs the GitHub App and makes the operator the first admin. Users install
the App on their own accounts and own those installations: they decide who else
may see their repositories and reviews, and their reviews use their own
providers and review defaults ([ownership](#ownership-and-access-phase-7)).
Signed-in users have their own [pages](#user-pages-phase-8): their
repositories with the status of each review, the findings of a review, and,
for what they own, settings, access, and model providers. Admins see and
manage everything in AshAdmin. Findings that someone with write access
resolves on GitHub, or the owner dismisses, are not reported again in that
repository ([feedback](#feedback-phase-9)). Queued reviews now run in the
read-only jail, with base-commit rules and
explicit model settings, store their runs/findings at `:reviewed`, then post a
sanitized GitHub COMMENT review and transition to `:posted`. Posting retries use
the stored run without model calls. The plan lists what each later phase adds.

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
mix phx.server              # http://127.0.0.1:4000 (and /health)
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

**Reviewing locally.** Reviews clone into `.state/` here (`TACKLE_WEB_STATE_DIR`)
and run only in the review jail. On Linux the repository's dev shell (`nix
develop` or direnv) builds the jail and sets `TACKLE_WEB_REVIEW_JAIL` unless it
is already set, so `iex -S mix phx.server` is enough. Outside the dev shell,
point it at the launcher yourself:

```sh
nix build .#tackle-review-jail -o /tmp/tackle-review-jail   # from the repository root
export TACKLE_WEB_REVIEW_JAIL=$(readlink -f /tmp/tackle-review-jail)/bin/tackle-review-jail
iex -S mix phx.server
```

On `localhost` GitHub cannot deliver webhooks (the App is registered without
one), so request reviews on the repository's page (`/repos/:id`) as the
installation's owner, or from the console the way a `/tackle review` comment
does, with a login that has write access to the repository:

```elixir
require Ash.Query
repo = Tackle.Web.Forges.Repository |> Ash.Query.filter(owner == "acme" and name == "widgets") |> Ash.read_one!()

%{repository_id: repo.id, pull_number: 12, login: "octocat", profile: nil}
|> Tackle.Web.Triggers.CommandJob.new()
|> Oban.insert()
```

The review needs the repository enabled and its installation owner's models
(`/settings`). For real webhooks, put a tunnel that passes requests through
unchanged (cloudflared, ngrok; not smee.io, which re-encodes the body) in
front of port 4000, set the App's webhook URL to
`https://<tunnel>/webhooks/github` with a secret and its events (pull request,
issue comment, pull request review thread) on GitHub, and store the same
secret with `ForgeApp.configure/2` from `iex`.

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
| `TACKLE_WEB_REVIEW_JAIL` | unset (reviews fail closed) | absolute path to the `tackle-review-jail` exec-server launcher |
| `TACKLE_WEB_STATE_DIR` | `/var/lib/tackle-web` (in development `.state/` here) | repository clones and per-run worktrees; separate from `HOME` |
| `TACKLE_WEB_URL` | `http://localhost:4000` | the public URL, as the forge and browsers reach the app; an `https` URL turns on HTTPS redirects, HSTS, and secure cookies (see [sign-in](#sign-in-and-administration-phase-6)) |

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
directory (`stateDir`, `/var/lib/tackle-web`). `reviewJail` defaults to the
flake's `tackle-review-jail` package and sets `TACKLE_WEB_REVIEW_JAIL`. The
service permits Bubblewrap's unprivileged user namespaces; the host must also
allow them. Do not add a systemd namespace restriction that forbids `user`.

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

## Review jail

`nix build .#tackle-review-jail` builds the dedicated Linux launcher. It uses
read-only mounts for the worktree, its Git directory and the bare clone; it
creates no Git files on the host. It has no network, host Nix daemon or store
access beyond its tool closure, host Ketch configuration, credentials or service
environment. Its home and `/tmp` are private scratch space. Git reads use
`GIT_OPTIONAL_LOCKS=0`. This is distinct from the CLI's writable, networked jail.

`Tackle.Web.ReviewJail.start(%{worktree: absolute_path, clone: bare_clone_path,
state_dir: state_path})` starts a fresh client and probes write protection,
network isolation (against a temporary host loopback listener), and state
visibility on every launch. Paths must be resolved, disjoint clone/worktree
paths beneath the state directory, without symlink components. The worktree
must be a linked worktree of that clone. It returns `{:ok, handle}` with
`handle.client` and `handle.executor`, or a redacted error. Missing configuration
or failed probes never select a local executor. Pass `handle.executor` to the
review tools; call `ReviewJail.stop(handle)` in an `after` block after stopping
agents. Clients are not restarted without verification. Jailed stderr is
sent to `/dev/null`, not the application's logs.

Run the credential-free security smoke test on a Linux host (not inside a Nix
build sandbox; it needs user namespaces), from a writable directory outside
`/tmp`:

```sh
nix build .#tackle-review-jail.tests.smoke
./result/bin/test-tackle-review-jail
```

It exercises the production exec-server launcher, read-only Git operations,
network and state isolation, hidden Nix store data/daemon, unchanged host Git
data, and refusal of crafted Git pointers and symlinks.

## Setting up (in the browser)

After deploying, everything is done in the browser at `<TACKLE_WEB_URL>/setup`
(`Tackle.Web.SetupController`, rules in `Tackle.Web.Setup`); no secret is
copied by hand.

1. **Unlock setup.** While setup is incomplete (no GitHub App stored, or no
   admin), the server logs a one-time **setup token** at start:

   ```sh
   journalctl -u tackle-web | grep 'setup token'
   ```

   It lives in memory only; a restart makes a new one, and it stops working
   once setup is complete. Entering it unlocks setup for that browser for an
   hour. Without it, nobody who reaches a fresh server can register their own
   App and become its admin.
2. **Create the GitHub App.** Name it and, optionally, give the organisation
   to own it (empty: your personal account). GitHub's App manifest flow
   registers it with everything preset: webhook URL
   `<TACKLE_WEB_URL>/webhooks/github` and its events (pull request, issue
   comment, pull request review thread), the sign-in callback, public (so users can install it on their
   own accounts), and the permissions (Metadata,
   Contents read; Pull requests write; Issues read; organisation Members
   read). GitHub sends the browser back with a one-time code, and the App id,
   client id and secret, webhook secret, and private key go straight into the
   encrypted database. GitHub's manifest cannot set a logo: upload
   [`docs/assets/tackle-logo.png`](../../docs/assets/tackle-logo.png) (also
   served at `/assets/logo.png` and linked from the setup page) in the App's
   settings under "Display information".
3. **Install it** on the organisation (or account) whose pull requests it
   reviews. GitHub returns to `/setup/github/installed`; the installation is
   confirmed with GitHub and recorded with its repositories (disabled by
   default). "Sync from GitHub" does the same if that redirect was missed.
4. **Sign in with GitHub** from the same browser: that makes you the first
   admin. Setup is then complete and `/setup` closes.

Then enable repositories in the administration, or turn on "review every pull
request" for the whole installation there (see below). Any signed-in user
installs the App on further accounts from the start page; admins re-sync
installations there.

An App created before phase 7 is private, so only its own account can install
it: make it public in the App's GitHub settings (Advanced, "Make public") to
let users install it on theirs. Such an App also lacks the "Pull request
review thread" event that [feedback](#feedback-phase-9) needs: tick it under
the App's "Permissions & events".

**Locally** (`TACKLE_WEB_URL` on `localhost`) GitHub cannot deliver webhooks,
so the App is registered without one: installations come from the install
redirect and the sync button, and reviews do not start by themselves. A tunnel
URL as `TACKLE_WEB_URL` gets webhooks as in production. In development the
token is in the `mix phx.server` output.

**Recovery from the console.** `Tackle.Web.Release.configure_github_app/0`
stores an App from files (`TACKLE_WEB_GITHUB_APP_ID`, `…_CLIENT_ID`, and the
`…_PRIVATE_KEY_FILE`, `…_WEBHOOK_SECRET_FILE`, `…_CLIENT_SECRET_FILE` paths),
replacing the stored one; `set_admin/2` grants or revokes admin by login:

```sh
sudo tackle-web-release eval 'Tackle.Web.Release.set_admin("octocat")'
```

Until an App is stored, webhooks are answered with 503 and `/auth/github` with
503.

What happens with a pull request (`Tackle.Web.Triggers`):

- `/tackle review [quiet|default|assertive]` in a comment, from someone with
  write access, requests a review of the current head in any enabled
  repository.
- Repositories with `auto_review: :on_open` request one when a pull
  request is opened, reopened, or ready for review; `:on_open_and_push`
  also for every new head. Drafts and forks only with `auto_review_drafts`
  and `auto_review_forks`.
- A head is requested once. A command asks again after a review failure, or for a
  posted review with another profile. After a posting failure, a command with the
  same profile retries only posting, using the stored run. A new head skips the pending requests
  for older ones; closing a pull request skips its pending requests.

## Sign-in and administration (phase 6)

**Sign-in** is our own OAuth web flow through the GitHub App's client
(`Tackle.Web.AuthController`, `Tackle.Web.SignIn`), not a library:
`/auth/github` stores a random one-time `state` in the session and sends the
browser to GitHub; `/auth/github/callback` checks it, exchanges the code, reads
`/user`, revokes the user's token (best effort; it is never stored), and admits
the account only if it **owns or holds a grant on an active installation**
(checked in the database, see [ownership](#ownership-and-access-phase-7)), or
else belongs to an **active installation's account**: a member of the
organisation (asked with an installation token, Members read), or the user
account the App is installed on (compared by account id, not login). Then
the session is renewed and holds only the user id and sign-in time. Nobody can
sign in before the App is installed. Failures show a fixed message; GitHub's
details are only logged by kind.

The first **admin** is whoever signs in from the browser that unlocked setup
(above); signing in never makes anyone admin otherwise. Admins grant and
revoke it for others in the administration (User, `set_admin`); the last admin
cannot be removed, there or from the console.

Sessions are a signed and encrypted cookie (`SameSite=Lax`, `HttpOnly`) that
lasts seven days; the user is read from the database on every request and
mount, so deleting a user row or revoking admin takes effect at once. Forms use
Phoenix's CSRF tokens; sign-out is a `POST /sign-out`. With an `https`
`TACKLE_WEB_URL`, plain HTTP is redirected to it, HSTS is sent, and the cookie
is `Secure`. The reverse proxy must set `X-Forwarded-Proto` (overwriting any the
client sent); `/health` and requests to `localhost`/`127.0.0.1` stay on HTTP.

**Administration** is AshAdmin at `/admin`, for admins only (anyone else is sent
to the start page, or gets 403 when signed in). Admins read every record there.
The start page links to it; every signed-in user gets the install link and
`/codex-login`. What it offers:

| Resource | In the admin interface |
|---|---|
| Installation | read; `set_defaults` (with `apply_to_repositories` to reset every existing repository to the new defaults: "review every pull request"); `set_owner` (a user id) |
| Repository | read; `configure` (enabled, automatic review, forks/drafts, profile, settings JSON, daily budget); `apply_installation_defaults` |
| Access | read; `revoke` |
| Provider | read every user's; `register` (for the admin), and `configure`, `set_credentials` (OpenRouter API key, write-only) on the admin's own |
| ReviewDefaults | read every user's; `configure` (the admin's own row) |
| User | read; `set_admin` (never the last admin) |
| ForgeApp, ReviewRequest, ReviewRun, Finding | read only |

The GitHub App itself is created in setup; replacing or rotating its secrets is
not in the browser yet (the recovery command above). Paid reruns and posting
retries are not admin actions: installation owners request them on the user
pages ([phase 8](#user-pages-phase-8)), and the console does too (see below).

**Authorisation.** Every domain authorises when an actor is given
(`authorize :when_requested`): the web interface always passes the signed-in
user, and the resources' policies decide. Admins read everything; other users
read what they own or were granted (below). The actions in the table need an
admin, or the owner where the ownership section says so; every other action
(webhook syncs, recording owners, the review job's internal writes, credential
storage, reruns) is refused to any actor. Policies re-read the user (`Tackle.Web.Accounts.Check`) rather than trust
the actor a page holds. Calls without an actor are trusted server code (jobs,
webhooks, the console); AshOban's own authorised calls pass through a bypass.

AshAdmin normally lets the browser choose the actor and switch authorisation
off (cookies, connect parameters, sidebar events). Here its LiveView runs behind
`{Tackle.Web.Auth, :admin_ui}`, which re-reads the admin and pins the actor to
them with authorisation on before every `handle_params` and event, and ignores
the actor, authorisation and tenant events. No resource is an AshAdmin actor, so
there is no actor picker.

**Secrets** are `sensitive?` and never in `show_sensitive_fields`, and no
decrypting calculation is shown. AshCloak's `on_decrypt` refuses decryption
whenever an actor is present (`Tackle.Web.Vault.authorize_decrypt/4`), so the
web interface cannot read a secret back even by loading it; only server code
does. AshAdmin's show pages list the stored ciphertext columns, redacted.

## Ownership and access (phase 7)

Every installation belongs to the GitHub user who installed the App
(`Installation.owner_external_id`, the forge's user id, and `owner_login`;
plan §7.12). It comes from the signed `installation` `created` webhook's
sender, or, for an installation on a user account, from that account (in
webhooks and in syncs). It is recorded once and never changed by GitHub
events; GitHub's API does not say who installed an organisation's App, so an
organisation installation recorded without the webhook (a loopback URL, a missed
delivery, or before phase 7) has no owner until an admin sets one
(`Installation.set_owner`, by user id, in the administration). The setup
redirect, which the browser controls, never sets an owner.

| Who | Can |
|---|---|
| the owner | read the installation, its repositories, and their requests, runs, and findings; `Repository.configure`, `apply_installation_defaults`; `Installation.set_defaults`; grant and revoke access |
| a grantee | read the repositories granted, with their requests, runs, and findings |
| anyone signed in | register and change their own providers and review defaults; install the App |
| admins | everything above to read; the admin actions in the table above |

**Grants** (`Tackle.Web.Forges.Access`) are made by the owner for a GitHub
login, on the whole installation (including repositories added later) or on one
repository. `Access.grant(installation_id, login, %{repository_id: ...}, actor:
owner)` resolves the login to GitHub's user id first (`GET /users/{login}` with
the installation's token), so a grant works before the grantee signs in and
survives renames; granting again is a no-op. The owner and admins
`Access.revoke` it, which takes effect at the next read. Owners manage grants on
the repository and installation pages ([user pages](#user-pages-phase-8)), or
from the console:

```elixir
alias Tackle.Web.Accounts.User
alias Tackle.Web.Forges.{Access, Installation}
owner = User.get_external!(:github, "<owner's GitHub id>")
installation = Installation.get_external!(:github, "<installation id>")
Access.grant!(installation.id, "octocat", %{}, actor: owner)
```

**Reviews use the owner's models.** `Tackle.Web.ReviewJob` resolves the
installation's owner (`Installation.owner/1`) and uses only that user's enabled
providers and review defaults; a review of an installation without an owner, or
whose owner has not signed in yet, fails with a message that says so.

Migration `add_ownership_and_access` gives the existing providers and defaults
row to the oldest admin (provider ids become their names, so model references
keep working), and installations to the signed-in user whose login is the
installation's account, otherwise to the oldest admin. It refuses to run while
providers or defaults exist and nobody is an admin.

## User pages (phase 8)

LiveView pages for every signed-in user, under the top bar with the logo
(`Tackle.Web.Layouts`, components in `Tackle.Web.UI`, plain CSS in
`priv/static/assets/app.css` with a dark scheme, no asset build):

| Page | What it shows |
|---|---|
| `/` | the start page: what tackle is and "Sign in with GitHub"; signed-in users go on to `/repos` |
| `/repos` (`ReposLive`) | the installations and repositories the user owns or was granted, each with its latest review (and what it is doing while it runs); "Install on GitHub"; admins also get "Sync from GitHub"; until the user's own reviews can run, a "Getting started" checklist |
| `/repos/:id` (`RepositoryLive`) | the repository's latest 50 review requests with status, verdict, and posted findings; for the owner, a form to review a pull request, its review settings, and who has access |
| `/reviews/:id` (`ReviewLive`) | one request's progress while it runs (phases, parts reviewed, candidate findings and their verdicts), then its latest run: status, verdict, duration, tokens, and its findings (posted, verified but hidden, rejected) as plain text; for the owner, "Review again" and, after a posting failure, "Retry posting" |
| `/installations/:id` (`InstallationLive`) | its repositories; for the owner, the defaults for new repositories and access to all of them |
| `/settings` (`SettingsLive`) | the user's providers (add, store an OpenRouter key, enable or disable; whether each has credentials) and review defaults |
| `/codex-login` | connects one of the user's Codex providers; `?provider=<name>` preselects it |

**Requesting reviews.** The installation's owner requests a review of a pull
request on the repository's page, or of the same pull request again on a
review's page (`Tackle.Web.ReviewRequestComponent`). It does what a
`/tackle review [profile]` comment from them does
(`Tackle.Web.Triggers.owner_command/4`, which shares
`Triggers.run_command/4` with `CommandJob`): GitHub must report write access
for the owner's login, and the pull request's current head is reviewed, so a
head already reviewed with the same profile is not reviewed (and paid for)
again; another profile reviews it again. The forge calls run as an async task
of the page, and the page says why nothing was requested (closed, no write
access, not found). "Retry posting" calls `Posting.retry/1`: it posts the
stored run again without model calls.

**Getting started.** For users who own an installation or have none yet,
`/repos` lists what their reviews still need until all is done: an
installation of their own, a connected and enabled provider, detector and
verifier models in their review defaults, and a first review.

**In the browser.** Links between the pages navigate over the LiveView
connection; `app.js` marks the top bar's current section, asks before
destructive clicks (`data-confirm`, optionally only while a checkbox is
checked with `data-confirm-if`), and copies the Codex code (`data-copy`).
Buttons are disabled while their event runs.

The lists show only what the user owns or was granted, admins included
(`Forges.AccessCheck.visible/2`); every read and write runs with the user as
the actor, so the policies decide, and pages re-read the user before every
event and update, so an expired sign-in stops an open page. Pull request titles are stored with
review requests (from the webhook or the pull request read by a command) for
these pages. Finding text comes from the models and is never rendered as HTML.

**Live.** While connected, the pages follow what they show and read it again
when it changes: `Tackle.Web.Updates` is an Ash notifier on the review,
forge, and model resources that sends a message with only a topic (a
request, a run's findings, a repository, its dismissals, an installation,
all installations and grants, a user's providers) once the write commits,
and the page reads again as its user, once for a burst of changes. A page
whose user lost access leaves on the next change, and a settings form being
edited is kept. Writes inside a transaction must use `Ash.transact/3` (as the
review job's `Store` and the credential store do) so their notifications wait
for the commit; tests raise on missed notifications.

While a review runs, its job reports what it is doing to
`Tackle.Web.ReviewProgress`: the phase (fetching the pull request, starting
the jail, reading the change and rules, reviewing, storing, posting) and the
review's events: its parts with their status, and the candidate findings
with their verifier verdicts, as the CLI's review view shows them. The
review page shows all of it; the repository and repositories pages say what
an in-flight review is doing. The progress lives in a `Registry` owned by
the job's process, so it ends with the job and a page opened mid-review
starts from it; with several nodes, pages on another node get the messages
but not the progress so far.

The page tests render over HTTP and call the pages' events directly;
`Phoenix.LiveViewTest` would need the `lazy_html` package, which is not a
dependency.

## Feedback (phase 9)

`Tackle.Web.Feedback` turns what people do with posted findings into data
(plan §7.13):

- **Resolving a thread dismisses its finding.** A `pull_request_review_thread`
  delivery (`resolved` or `unresolved`) counts only when one of the thread's
  comment ids is a line comment tackle posted in that repository
  (`Finding.forge_comment_id`); text in comments is never trusted. The webhook
  queues `Tackle.Web.Feedback.Job`, which checks that the person has write
  access (a pull request's author may resolve threads too, and must not hide
  findings that way), then records a `Tackle.Web.Reviews.Dismissal` for the
  repository and fingerprint (`source: :forge`), or removes it on
  `unresolved`. Bots' changes are ignored.
- **The owner dismisses on the review page** (`source: :web`) and restores on
  the review or repository page; grantees see dismissals but cannot change
  them, and admins can restore in AshAdmin.
- **Reviews skip dismissed findings**: `ReviewJob` passes the repository's
  dismissed fingerprints to `Tackle.Review.run/2` as `:known_fingerprints`.
- **Reactions** (👍/👎) on posted comments are read when a pull request with
  posted comments gets a new head or is closed (one job per pull request per
  minute; `GET /repos/{owner}/{repo}/pulls/{number}/comments`) and stored on
  the findings (`reactions_up`, `reactions_down`), shown on the review page.
  They are counts only and never dismiss anything.

A resolve and an unresolve in quick succession are separate jobs and can run
in either order; the thread's last state is not read back from GitHub.

## Models and credentials (phase 3)

`Tackle.Web.Models.Provider` registers an adapter instance owned by a user with
`register(name, adapter, attrs)`: with a signed-in actor the owner is the
actor; trusted code passes `owner_id` in `attrs`. Names use lowercase
letters/digits and inner hyphens, are unique per owner, and are what model
references start with; adapters are **only** `:openrouter` or `:codex`. Several
names can use the same adapter. New providers are disabled until they first
get credentials (an API key or a Codex login), which enables them; one
disabled later stays disabled when its credentials change. `configure/2`
changes `settings` (an opaque string-keyed JSON map) and `enabled`, not name,
owner, adapter, or credentials. `Models.enabled_providers(owner_id)` builds
`Tackle.Lib.LLM.Provider` instances of one owner without loading secrets.

Provider credentials are encrypted with AshCloak and the existing AES-GCM
vault. Normal resource reads leave `credentials` unloaded and sensitive.
OpenRouter's `Provider.set_credentials(provider, api_key)` accepts a nonempty
key and stores `%{"api_key" => key}`; it rejects Codex providers. **Do not set
`OPENROUTER_API_KEY` in the service environment**: that adapter's fallback for
the default `openrouter` id would bypass database-only configuration.

The `connected` calculation says whether credentials are stored without
decrypting them; deleted credentials are stored as SQL NULL
(`encrypt_nil? false`).

`Tackle.Web.CredentialStore.handle(owner_id)` is
`{Tackle.Web.CredentialStore, owner_id}`, and ids in it are provider names.
Pass the owner's handle as the backend/adapter's `:credential_store` for every
run, so Codex's refresh lock serialises refresh-token rotation. `fetch/2` reads Postgres afresh, `put/3`
writes transactionally, and `delete/2` removes only credentials. Missing or
cleared credentials return `:error`; writes to missing providers return
`{:error, {:unknown_provider, name}}`; deletion is idempotent. Disabled providers
keep their credentials. JSON-compatible credential maps are opaque to the
store; adapter token refreshes can write them back through the same handle.

`Tackle.Web.Models.ReviewDefaults.configure/1` replaces a user's row's
`models` and `thinking` maps (the actor's, or `user_id` from trusted code), keyed by stage strings (`"detector"`,
`"verifier"`, `"scorer"`). Partial defaults can be saved, but there is **no
implicit model** and a review cannot resolve until detector and verifier are
set, in defaults or repository settings. Admins do this for themselves in the
administration (`/admin`, Models); until the user pages (phase 8), the same for
any user from the trusted server console:

```elixir
alias Tackle.Web.Accounts.User
alias Tackle.Web.Models.{Provider, ReviewDefaults}
owner = User.get_external!(:github, "<GitHub user id>")
Provider.register!("openai-codex", :codex, %{enabled: true, owner_id: owner.id})
ReviewDefaults.configure!(%{
  user_id: owner.id,
  models: %{
    "detector" => "openai-codex/gpt-6.1-sol",
    "verifier" => "openai-codex/gpt-6.1-sol"
  },
  thinking: %{"detector" => "low", "verifier" => "medium"}
})
```

`Models.resolve_settings(owner_id, repository.settings, resolved_profile)` returns
`{:ok, %Tackle.Review.Settings{}}` or an error, including
`{:missing_review_models, stages}`. Repository model/thinking entries override
defaults **per stage**; step limits and default rules remain repository/review
choices, and profile is passed separately. The scorer model is optional and
inherits the requester's when absent. Repository and default settings validate
model references against the owner's enabled providers when saved and again at resolution;
disabling a provider can therefore make an existing configuration fail with an
explicit error. This checks adapter catalogs, not live subscription access or
whether credentials are present.

### Codex device login

`Tackle.Web.Models.CodexDevice.request(owner_id, name, opts)` verifies the
owner's provider uses Codex and calls
`Tackle.Plugins.Codex.OAuth.request_device_code/1`. It returns
`{:ok, %{owner_id: owner_id, provider: name, device: device}}`; display only `device.user_code` and
`device.verification_uri`. Run `CodexDevice.complete(flow, opts)` in a task: it
polls and exchanges the code, then writes credentials to that provider's
encrypted database row. Success returns `:ok`, never tokens; errors leave
existing credentials intact. Options are trusted server OAuth options, never
request parameters. A disconnected page's async task exits with the LiveView.

`/codex-login` (`CodexLoginLive`) is that flow's page, for any signed-in user and
their own providers only: register a provider with adapter `codex`, open the
page, pick it, and enter the shown code at the verification URL. The router
requires a user for the request, the `{Tackle.Web.Auth, :require_user}` hook
again on the HTTP and the connected mount, and the page re-reads the user and
names the provider by that user's id before it starts a login.
Raw OAuth errors are not displayed because upstream responses may contain secrets.

### Agent backend

`Tackle.Web.AgentBackend` implements `Tackle.Runtime.AgentBackend` directly on
`Tackle.Lib`, without local harness configuration, sessions or persistence.
`config/1` takes explicit `providers`, `owner_id` (whose providers they are) and
`model`, plus `tools`, `system_prompt`, `context`, `llm_opts`, `thinking` and
`max_steps`. It always installs the owner's `CredentialStore.handle/1` in
adapter options. Put the resulting config in an
`AgentSpec` and choose this backend in the `ScopeSpec`.

The backend supports review configuration callbacks, model/thinking inheritance,
streaming subscriptions, snapshots, and one turn at a time. Cancellation is
cooperative; stopping an agent also stops its linked turn task. Scopes, tools,
executor selection and teardown remain the caller's responsibility. The backend
does not default to a local executor: `ReviewJob` supplies the review jail and
owns the run lifecycle. Tests use scripted adapters, not provider credentials.

## JSON

Our code uses Elixir's standard `JSON` module, as everywhere in this
repository; Phoenix is configured to use it too. Ash, Oban, Postgrex, and
Cloak pull in Jason as a transitive dependency, which is accepted; do not
add it to `mix.exs` or call it.

## Checkout (phase 4 slice)

`Tackle.Web.Checkout.prepare(request)` accepts a review request (a struct or
atom-keyed map with `id`, `repository_id`, `base_sha`, `head_sha`, `base_ref`,
`pull_number`, `head_is_fork`). It loads the repository, installation and forge
app, returning `{:ok, handle}` or `{:error, sanitized_atom}`. The handle has
absolute, symlink-free `worktree`, `clone`, `state_dir`, and the three IDs.
Pass it directly to `ReviewJail.start/1`; pass `state_dir` as the review change's
confinement workspace. After stopping agents and the jail, call
`Checkout.cleanup(handle)` in an `after` block (idempotent). Keep the process
that prepared it alive until cleanup; another process cannot clean its live
lease. Only Git mutations hold the repository lock; model execution must not.

Clones have full bare history under `repos/<installation UUID>/<repository
UUID>`. A fetch updates the base branch and `refs/pull/N/head` from the base
repository, including fork PRs. Missing requested SHAs are fetched explicitly
by SHA, including heads no longer reachable after a force push. Both must be
available commit objects; the detached worktree uses the exact requested head.
New clones are validated in a staging directory before atomic publication.
Retries discard abandoned staging data and stale Git lock files only after
waiting for cancelled Git processes to stop; existing caches with worktrees
are never replaced. Invalid existing caches with worktree metadata or checkout
manifests are preserved for operator inspection. Invalid IDs, SHAs, refs, noncanonical URLs and symlink
components fail closed. The state directory must already be an absolute,
resolved path (symlinks are rejected, not silently followed).

`Forge.clone_auth(app, installation, repository)` returns
`{:ok, %{url: canonical_https_url, authorization: sensitive_header}}`.
GitHub uses its cached short-lived installation token. Only clone/fetch receive
that header via command-scoped `GIT_CONFIG_COUNT`/`extraHeader`; no credentials
enter URLs, argv, config, returned handles, Git errors or the jail. Git starts
with inherited environment variables explicitly removed, system/global config
and hooks disabled, file transport and redirects forbidden, and credential
helpers disabled. System TLS trust uses `/etc/ssl/certs/ca-certificates.crt`
when available, never inherited CA overrides. Host Git requires Bash (with
`wait -n -p`), util-linux `setsid`/`flock`, and coreutils on PATH (provided by the
NixOS module). A pipe-watching guardian sends TERM then bounded KILL to Git's
entire process group on its 120-second command timeout or caller cancellation.
A repository OS lock remains held through teardown, preventing a new owner
from recovering metadata while old Git processes are still writing.
Git output is discarded
except for an internal bounded exact-SHA check and is never returned or logged.

`Checkout.sweep()` is the startup stale-worktree API. It removes only worktrees
with valid service-written manifests under `checkouts/<request UUID>`, then
prunes that shared clone under the same repository lock. Lease registration,
liveness checks and removal share that lock. Global process leases protect live
checkouts across connected nodes. The default database liveness
check additionally preserves **all** worktrees while any Oban job in the
`reviews` queue is `executing`, even if its request is not `running`; conversely,
a `running` status left after a crash is not evidence of a live job. Database
errors fail closed. Unknown/malformed manifests and unrecorded worktrees are
left untouched for operator inspection, and clones are never swept away.

`ReviewJob.Sweeper` runs after Repo starts and before Oban consumers start,
and repeats every minute, including after Lifeline recovers abandoned jobs.
Missing databases/tables during migration tasks do not prevent startup: sweep
fails closed and tries later. An executing job left by a crash conservatively
delays cleanup until recovery.
Do not run two disconnected nodes against the same state directory: global
locks and leases require connected BEAM nodes and one shared path namespace.
The state tree is host-owned and must never be writable by reviews or other
untrusted host processes; symlink checks are not a race-proof substitute for
that ownership boundary.


## Review jobs and stored results (phase 4)

`Triggers` immediately enqueues `ReviewRequest`'s AshOban `:run` trigger inside
its upsert transaction. The minute scheduler is a safety net. Jobs are unique
on their worker/request primary key while queued, executing or retryable. The
`reviews` queue currently runs one job at a time; each has three attempts and a
20-minute timeout. Lifeline's 30-minute rescue threshold must remain longer
than that timeout.

`ReviewJob.run(%{request_id: uuid, job: oban_job})` is plain Elixir. The manual
Ash action extracts the **actual** job from `changeset.context.ash_oban.job`.
A short advisory-lock/row-lock transaction verifies its persisted executing
attempt and records `claimed_job_id`/`claimed_attempt`. A duplicate live attempt
does no work; a larger attempt of that same job can reclaim an abandoned run.
No database connection or Git mutation lock spans model calls. Disabled or
inaccessible repositories/installations and exhausted UTC-day token budgets
are skipped before checkout. Runtime model resolution checks defaults and
currently enabled providers again; displayed failures are sanitized.

Each run loads `base...head` with the state directory as confinement workspace,
reads rules from the **base commit**, and passes warnings to the result. Its
root never runs a turn; detector/verifier agents have explicit models, prompts,
step limits and only Read, Bash and their reporting tools. Every tool uses the
verified jailed executor. There is no local fallback or harness configuration.
Known fingerprints are empty until phase 7 supplies outcomes.

An unlinked, monitored per-run lifecycle owner prepares the checkout, starts the
jail and starts a preallocated runtime scope. It keeps the checkout lease alive
until cleanup. On normal completion, failures, caller termination or Oban timeout,
it stops the scope, then jail, then checkout. Serializing acquisition in that
owner prevents caller death between resource creation and registration from
orphaning globally supervised agents. Failed cleanup is revisited by the sweep.

One fenced transaction creates `ReviewRun`, creates shown/rejected findings
and `Result.hidden/1` (not unverified deterministic drops), and sets `:reviewed`.
Summary/usage maps recursively normalize nested structs, atoms and failure
terms for standard-library JSON; unsupported values are replaced, not inspected.
Findings retain support/verdict, rejection evidence and structured hidden reasons.
Budgets sum normalized total tokens of this repository's stored runs in the UTC
calendar day; failed attempts without a stored result have no usage to count.
This is a pre-run threshold, not a hard in-flight token cap.

Normal failures remain `:running` for Oban retries; AshOban's final-error action
sets `:failed`. Timeouts/killed processes bypass that action: the next scheduled
job detects a discarded, cancelled, completed-without-result or missing owner
and marks the request failed **without another paid three-attempt cycle**.
`:posted`, `:failed` and `:skipped` are terminal no-ops. `:reviewed` attempts only
post. A trusted manual `ReviewRequest.rerun/2` clears ownership and returns a
finished request to pending, retaining all previous runs/findings; this explicitly
requests a new paid review, unlike the posting-only retry below.

Tests use fake models and trusted checkout/jail seams, not live provider calls;
the separate checkout and jail tests cover their fail-closed boundaries. These
options belong only to trusted host code, never HTTP inputs or persisted settings.

## Forge posting (phase 5)

After storing the result, `ReviewJob` tears down agents, jail and checkout,
then calls `Posting`. Posting an existing `:reviewed` request requires no model,
checkout, jail, or token-budget admission. Disabled/inactive repositories or
installations stop posting without deleting the paid result.

`Posting.Format` builds forge-neutral text and locations. Only shown findings
are posted. Findings on the diff become line comments (new/RIGHT or old/LEFT;
multiline only within one hunk); others go in the review body. The current PR's
base/head are checked before and after reading diff files. A changed revision,
missing patch, truncated hunk or omitted file falls back to the body; the review
is always pinned to the stored head. The header gives verdict, counts, profile
and units. Previously posted fingerprints are mentioned as still present, not
posted again, including findings that previously appeared only in a review body.

Model text is plain escaped prose: HTML/entities and Markdown links/images are
escaped, mentions and issue-closing syntax neutralized. Suggestions use code
fences longer than embedded fences. Code may contain inserted zero-width spaces
at mention/closing syntax; inspect it before copying. Text fields are capped,
line comments limited to 25, and the body bounded below 60,000 bytes, with
notices for omissions. Omitted findings are not marked as already posted.

The sanitized payload is frozen in the run's `summary["posting"]` before POST.
Its body starts with `<!-- tackle-review:<run UUID> -->`; line comments carry
`<!-- tackle-finding:<fingerprint> -->`. GitHub lookup checks the app bot's
identity and paginates reviews; comment recovery also paginates. Every retry
looks up the run marker before creating a review, including after a lost POST
response or failed comment-ID lookup. POST is never automatically retried or
redirected. Review ID, comment IDs and posted fingerprints are persisted in a
single fenced transaction, along with `:posted`; run metadata survives request
reruns. Only shown inline findings receive `forge_comment_id`.

A per-PR lock serializes posting across heads on this node and connected BEAM
nodes; disconnected application nodes sharing a database are unsupported.
No database connection is held during HTTP. An unresolved prepared posting
blocks later runs of the PR until it is recovered or explicitly superseded by a
paid rerun. If a previous run's response was lost, later runs check its marker
before deciding which fingerprints are already posted. GitHub has no atomic
idempotency-key API: marker recovery assumes accepted reviews are visible to
subsequent reads; the database and forge cannot share a transaction.

Posting failures retain `:reviewed` for Oban retries. Exhausted/cancelled jobs
become `:failed` with a fixed, redacted posting error, rather than creating
endless new retry cycles. After repairing access or configuration, the
installation's owner clicks "Retry posting" on the review's page, or use the
trusted console (there is no admin action for it):

```elixir
Tackle.Web.Posting.retry(request_id)
```

This restores `:reviewed` and enqueues posting of the same run. It rejects review
failures and live posting attempts. `/tackle review` with the same profile after
a posting failure does the same; a different profile or explicit
`ReviewRequest.rerun/2` asks for a new paid review. The minute scheduler remains a
safety net if immediate enqueue merges with an ending job.

**Deployment:** no schema/dependency change is required. Existing `:reviewed`
requests become eligible for posting on the next scheduler tick. Configure the
GitHub App's Pull requests write permission before deploying; disable repository
reviewing to pause side effects while preparing the rollout.

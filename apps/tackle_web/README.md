# tackle_web

**Status: phases 1–5 of
[`docs/TACKLE_WEB_PLAN.md`](../../docs/TACKLE_WEB_PLAN.md).**
A web app that will review pull requests with
[`tackle_review`](../../packages/tackle_review/README.md) and post the
findings to the forge. So far it receives GitHub webhooks: it keeps track
of the GitHub App's installations and repositories, and turns pull request
events and `/tackle review` commands into review requests according to
each repository's settings. It also stores model providers and encrypted
credentials, resolves review defaults, and has an ephemeral agent backend tested
with whole scripted reviews. Codex device login has a server service and an
unmounted page awaiting phase 6's authentication. Queued reviews now run in the
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
| `TACKLE_WEB_REVIEW_JAIL` | unset (reviews fail closed) | absolute path to the `tackle-review-jail` exec-server launcher |
| `TACKLE_WEB_STATE_DIR` | `/var/lib/tackle-web` | repository clones and per-run worktrees; separate from `HOME` |
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
- A head is requested once. A command asks again after a review failure, or for a
  posted review with another profile. After a posting failure, a command with the
  same profile retries only posting, using the stored run. A new head skips the pending requests
  for older ones; closing a pull request skips its pending requests.

## Models and credentials (phase 3)

`Tackle.Web.Models.Provider` registers an adapter instance with
`register(id, adapter, attrs)`: ids use lowercase letters/digits and inner
hyphens, and adapters are **only** `:openrouter` or `:codex`. Several ids
can use the same adapter. New providers are disabled; `configure/2` changes
`settings` (an opaque string-keyed JSON map) and `enabled`, not id, adapter,
or credentials. `Models.enabled_providers/0` builds `Tackle.Lib.LLM.Provider`
instances without loading secrets.

Provider credentials are encrypted with AshCloak and the existing AES-GCM
vault. Normal resource reads leave `credentials` unloaded and sensitive.
OpenRouter's `Provider.set_credentials(provider, api_key)` accepts a nonempty
key and stores `%{"api_key" => key}`; it rejects Codex providers. **Do not set
`OPENROUTER_API_KEY` in the service environment**: that adapter's fallback for
the default `openrouter` id would bypass database-only configuration.

`Tackle.Web.CredentialStore.handle/0` is always
`{Tackle.Web.CredentialStore, :default}`. Pass that same value as the
backend/adapter's `:credential_store` for every run, so Codex's refresh lock
serialises refresh-token rotation. `fetch/2` reads Postgres afresh, `put/3`
writes transactionally, and `delete/2` removes only credentials. Missing or
cleared credentials return `:error`; writes to missing providers return
`{:error, {:unknown_provider, id}}`; deletion is idempotent. Disabled providers
keep their credentials. JSON-compatible credential maps are opaque to the
store; adapter token refreshes can write them back through the same handle.

`Tackle.Web.Models.ReviewDefaults.configure/1` replaces the singleton's
`models` and `thinking` maps, keyed by stage strings (`"detector"`,
`"verifier"`, `"scorer"`). Partial defaults can be saved, but there is **no
implicit model** and a review cannot resolve until detector and verifier are
set, in defaults or repository settings. For example, after registering and
enabling the Codex provider (trusted server console, not a public endpoint):

```elixir
alias Tackle.Web.Models.{Provider, ReviewDefaults}
Provider.register!("openai-codex", :codex, %{enabled: true})
ReviewDefaults.configure!(%{
  models: %{
    "detector" => "openai-codex/gpt-6.1-sol",
    "verifier" => "openai-codex/gpt-6.1-sol"
  },
  thinking: %{"detector" => "low", "verifier" => "medium"}
})
```

`Models.resolve_settings(repository.settings, resolved_profile)` returns
`{:ok, %Tackle.Review.Settings{}}` or an error, including
`{:missing_review_models, stages}`. Repository model/thinking entries override
defaults **per stage**; step limits and default rules remain repository/review
choices, and profile is passed separately. The scorer model is optional and
inherits the requester's when absent. Repository and default settings validate
model references against enabled providers when saved and again at resolution;
disabling a provider can therefore make an existing configuration fail with an
explicit error. This checks adapter catalogs, not live subscription access or
whether credentials are present.

### Codex device login: server service and unmounted page

`Tackle.Web.Models.CodexDevice.request(provider_id, opts)` verifies the provider
uses Codex and calls `Tackle.Plugins.Codex.OAuth.request_device_code/1`. It returns
`{:ok, %{provider_id: id, device: device}}`; display only `device.user_code` and
`device.verification_uri`. Run `CodexDevice.complete(flow, opts)` in a task: it
polls and exchanges the code, then writes credentials to that provider's
encrypted database row. Success returns `:ok`, never tokens; errors leave
existing credentials intact. Options are trusted server OAuth options, never
request parameters. A disconnected page's async task exits with the LiveView.

**Credential management is not exposed over HTTP.** `CodexLoginLive` contains
the small async device-code UI but is deliberately **unmounted**, and its
`mount/3` also fails closed. Sessions, a LiveView socket, and browser assets
have not been wired up. Phase 6 must add those, CSRF protection, and admin
policies for resource actions; only then mount the page behind an authenticated
admin `on_mount` guard (on both disconnected and connected mounts), replacing
the fail-closed mount with that actor check and initial `status: :ready`,
`device: nil` assigns. Do not trust client-supplied session flags or expose
these trusted server actions through unauthenticated AshAdmin. Raw OAuth errors
are not displayed because upstream responses may contain secrets.

### Agent backend

`Tackle.Web.AgentBackend` implements `Tackle.Runtime.AgentBackend` directly on
`Tackle.Lib`, without local harness configuration, sessions or persistence.
`config/1` takes explicit `providers` and `model`, plus `tools`, `system_prompt`,
`context`, `llm_opts`, `thinking` and `max_steps`. It always installs
`CredentialStore.handle/0` in adapter options. Put the resulting config in an
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
endless new retry cycles. After repairing access or configuration, use the
trusted console (there is no unauthenticated HTTP/admin action):

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

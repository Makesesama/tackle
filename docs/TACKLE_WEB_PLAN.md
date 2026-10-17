# tackle_web plan: forge review bot

**Status: phases 1–6 of §8 are implemented in `apps/tackle_web` and
`nix/`: skeleton/packaging, forges/webhooks, models/agent backend, jailed review
jobs with stored runs/findings, retry-safe sanitized GitHub posting
(`:reviewed` → `:posted`), and GitHub sign-in with AshAdmin and the Codex
device-login page behind admin policies, web-only setup (phase 6b, §7.11),
ownership and access (phase 7, §7.12), the user pages (phase 8), and
feedback (phase 9, §7.13): every phase of §8 is implemented.** This document is a handoff: it should be enough to start without the conversation
that produced it. Read [`AGENTS.md`](../AGENTS.md) first; its rules apply.

## 1. Goal

A web application, `apps/tackle_web`, that reviews pull requests of a
company's repositories with `packages/tackle_review` and posts the findings
as a review on the pull request.

- One company, one NixOS server on the local network. Nothing should block a
  later hosted, multi-tenant version, but tenancy, billing, and sign-up are
  not built. From phase 7, users install the App on their own accounts and
  own what they install (§7.12); that is ownership inside one server, not
  tenancy.
- GitHub only for the MVP. Gitea is deferred and not part of the MVP; the
  forge behaviour (§7.1) keeps it a new module later, but nothing
  Gitea-specific is built now.
- No chat feature for now.

The name reuses `apps/tackle_web`, deleted in `c6c9e84` (an unrelated,
unmaintained Phoenix app); nothing from it is reused.

## 2. Decisions taken

| Topic | Decision |
|---|---|
| Database | PostgreSQL |
| Application framework | **Ash** for the data model, actions, and admin: `ash`, `ash_postgres`, `ash_oban`, `ash_cloak`, `ash_phoenix`, `ash_admin` (≥ 1.3.2). Not for the core review flow, which stays plain Elixir modules. |
| Admin UI | **AshAdmin** for managing resources instead of hand-built CRUD pages (§7.9). |
| Model providers | **OpenRouter** (`packages/tackle_openrouter`, `Tackle.Plugins.OpenRouter`, API key) and **OpenAI Codex** (`packages/tackle_codex`, `Tackle.Plugins.Codex`, ChatGPT OAuth through the device-code flow) are bundled. They are the only adapters the app accepts (§7.2). |
| Job queue | **Oban**, driven through AshOban |
| Secrets in the database | **Cloak** vault through AshCloak, cipher `Cloak.Ciphers.AES.GCM` (authenticated; Cloak's AES-CTR cipher has a high-severity advisory, do not use it). Applies to provider credentials and to forge integration secrets. |
| Web | Phoenix with LiveView, Bandit |
| HTTP client | `req` |
| Harness | **`tackle_web` does not depend on `packages/tackle`.** See §4. |
| `packages/tackle_phoenix` | Not used. |
| Sign-in | Not ash_authentication; a small GitHub OAuth flow of our own (§7.6). ash_authentication only covers sign-in, not repository access, and has a long advisory history (session fixation, OAuth identity linking to the wrong account in its GitHub strategy). |
| JSON | Our code uses Elixir's standard `JSON` module only. Jason as a **transitive** dependency (Ash, Oban, Cloak, Ecto pull it in) is accepted; do not add it directly. Update the JSON rule in `AGENTS.md` to say so in phase 1. |
| Hosting | NixOS; a Nix package and a NixOS module in this flake. Making the server reachable for forge webhooks (reverse proxy, tunnel) is the operator's job. |

Verified before handoff: `ash` 3.36, `ash_postgres` 2.14, `ash_oban` 0.10,
`ash_cloak` 0.4, `ash_phoenix` 2.3, `ash_admin` 1.3.2, `oban` 2.24, and
`cloak` 1.1 resolve and compile on this repository's toolchain (Elixir
1.20.4, OTP 29). `ash_admin` must be at least 1.3.2: the 0.x line has open
advisories, including a high-severity stored XSS. An
AshCloak attribute with the AES-GCM cipher stores ciphertext and decrypts on
read. Ash requires `config :ash, default_string_length_count: :codepoints`.
Dependencies emit Elixir 1.20 type-checker warnings while compiling; they do
not affect `--warnings-as-errors` for our own code.

## 3. Repository state at handoff

Recent commits that this plan builds on (see `docs/REVIEW_PACKAGE_PLAN.md`):

- `packages/tackle_review` (`Tackle.Review.*`): code review on
  `tackle_runtime`, without harness code or storage.
- `packages/tackle_tools` (`Tackle.Tools.{Read,Bash,Edit,Write}`,
  `Tackle.Executor.{Local,Jailed}`): the coding tools and executors, on
  `tackle_lib` and `tackle_exec` only.
- `packages/yaml_frontmatter`, `packages/gix_ex` (with `GixEx.read_dir/4`).
- `tackle_runtime`'s `AgentBackend` has optional `configure/2`,
  `describe/1`, and `llm/1` callbacks that reviews require.

## 4. Architecture

```
tackle_lib ◄── tackle_runtime ◄── tackle_review (+ gix_ex, yaml_frontmatter)
    ▲               ▲                  ▲
tackle_tools        │                  │
(+ tackle_exec)     │                  │
    ▲               │                  │
    └────────── tackle_web ────────────┘
                Phoenix · Ash/AshPostgres · Oban · Cloak · req
                + tackle_openrouter, tackle_codex
```

Why not the harness: `packages/tackle` is built for a local agent:
`config.json` and `TACKLE_HOME`, file sessions and journals, a file
credential store, agent/skill/`AGENTS.md` discovery, and `Tackle.Session` as
its agent process. None of that maps to a server with Postgres. Everything
the app needs is in the packages above:

| Need | From |
|---|---|
| Scopes, admission, limits, delegation, cancellation, supervision | `tackle_runtime` |
| The agent process itself | **the app's own backend** (§7.3) |
| Providers and model selection | `Tackle.Lib.LLM.Provider`, `Tackle.Lib.LLM.select/2` |
| Credentials for adapters | the app's `Tackle.Lib.CredentialStore` on Postgres (§7.2) |
| Thinking levels | `Tackle.Lib.Thinking` |
| `read`, `bash`, jailed execution | `tackle_tools`, `tackle_exec` |
| Review stages, rules, settings, pipeline | `tackle_review` |

`tackle_runtime` supervises scopes and agents, but leaves the agent process
to the host: `Tackle.Runtime.AgentSupervisor` starts whatever
`backend.child_spec/2` returns. That process is what differs between a
local host (the harness's `Tackle.Session`) and this app.

Ash is confined to `apps/tackle_web`. The packages stay framework-free.

## 5. Application layout

OTP application `:tackle_web`, namespace `Tackle.Web.*` (as the CLI uses
`Tackle.CLI.*`). A separate Mix project under `apps/tackle_web`, with path
dependencies on the packages, like `apps/tackle_cli`. Phoenix is written by
hand or with `mix phx.new --no-...` trimmed down; no Tailwind/esbuild build
step at first (Phoenix and LiveView ship their JavaScript; styling is plain
CSS), so the Nix build stays simple.

Suggested modules:

```
Tackle.Web.Application
Tackle.Web.Repo                       AshPostgres repo
Tackle.Web.Vault                      Cloak vault (AES.GCM, key from env)
Tackle.Web.Endpoint / Router / *Live  Phoenix
Tackle.Web.Forges        (Ash domain) Installation, Repository
Tackle.Web.Reviews       (Ash domain) ReviewRequest, ReviewRun, Finding, Dismissal (§7.13)
Tackle.Web.Models        (Ash domain) Provider (+ encrypted credentials)
Tackle.Web.Accounts      (Ash domain) User (sign-in)
Tackle.Web.Forge                      behaviour (§7.1)
Tackle.Web.Forge.GitHub               GitHub App client, webhooks, posting
Tackle.Web.AgentBackend               runtime backend (§7.3)
Tackle.Web.CredentialStore            Tackle.Lib.CredentialStore on Postgres
Tackle.Web.Checkout                   clones and worktrees (§7.4)
Tackle.Web.ReviewJob                  runs one review request (§7.5)
Tackle.Web.Posting                    findings → forge review (§7.5)
```

## 6. Data model (Ash resources on AshPostgres)

All timestamps UTC. Every row hangs off an installation, so a later
multi-tenant version adds an account above it (Ash attribute multitenancy)
instead of rewriting tables. Phase 7 adds installation owners, access
grants, user-owned providers, and per-user review defaults (§7.12); the
list below describes the resources before that phase.

**Forges**

- `Installation`: `forge` (`:github` for now), `external_id`, `account`
  (org/user login), `review_new_repositories` (default false) and
  `default_auto_review` (default `:off`, see `Repository.auto_review`): the
  defaults a repository gets when it is added to the installation, so "review
  every pull request in the organisation" is one setting. Identity on
  (`forge`, `external_id`).
- `ForgeApp`: the integration's secrets per forge. GitHub: `app_id`,
  `client_id`, and the encrypted (AshCloak) `private_key`,
  `webhook_secret`, and `client_secret`. One row per forge.
- `Repository`: `installation`, `owner`, `name`, `external_id`, `enabled`
  (default: the installation's `review_new_repositories`), `auto_review`
  (`:off` | `:on_open` | `:on_open_and_push`, default: the installation's
  `default_auto_review`), `auto_review_forks` (default false),
  `auto_review_drafts` (default false), `profile`
  (`:quiet` | `:default` | `:assertive`), `settings` (the JSON form of
  `Tackle.Review.Settings`, validated with `Settings.from_json/1` and
  `Settings.new/2`; a `profile` key is rejected there, `profile` above is
  the only place for it), `daily_token_budget`. Identity on
  (`installation`, `external_id`).

**Precedence.** Profile: the command's (`ReviewRequest.profile`), then
`Repository.profile`. Models and thinking levels, per stage: the
repository's `settings`, then `ReviewDefaults`. Step limits and default
rules: the repository's `settings`, then the stage profiles' and
`tackle_review`'s defaults. `Tackle.Web.ReviewJob` resolves these in one
place and passes the result to `Tackle.Review.run/2`.

**Reviews**

- `ReviewRequest`: `repository`, `pull_number`, `head_sha`, `base_sha`,
  `base_ref`, `head_is_fork`, `trigger` (`:command` | `:opened` | `:pushed`),
  `profile` (the profile the review uses, resolved when the request is
  made: the command's, or the repository's), `requested_by` (forge login), `status`
  (`:pending` | `:running` | `:reviewed` | `:posted` | `:failed` |
  `:skipped`), `error`, `forge_review_id` (when posted). `:reviewed` means
  the run and its findings are stored but not yet posted, so a retry posts
  without reviewing again (§7.5). Identity on (`repository`, `pull_number`,
  `head_sha`): webhook redeliveries and repeated commands upsert instead of
  reviewing twice. AshOban trigger on `status in [:pending, :running]` runs the `:run`
  action (§7.5); the trigger also includes `:reviewed` to retry posting stored
  runs without another review. `claimed_job_id`/`claimed_attempt` fence a running attempt;
  manual reruns clear them and retain historical runs.
- `ReviewRun`: `request`, `summary` (map: the `Tackle.Review.Result`
  summary, including stages, usage, settings, and the `rules`/`prompts`
  digests), `usage` (token totals for budgets), `duration_ms`,
  `verdict`.
- `Finding`: `run`, `fingerprint`, `state` (`:shown` | `:rejected` |
  `:hidden`), the finding fields (title, category, severity, blocking,
  confidence, rule_id, path, side, start_line, end_line, trigger, body,
  suggestion), `support`, `verdict`, `evidence` (rejected), `hidden_reason`
  (verified but hidden), `forge_comment_id` (when posted).
- `FindingOutcome` (as first sketched; phase 9 built `Dismissal` and
  reaction counts on `Finding` instead, §7.13): `repository`, `fingerprint`,
  `outcome` (`:dismissed` | `:fixed` | `:useful` | `:not_useful`), `source`
  (`:forge` | `:admin`), `by`, `note`. A repository's dismissed fingerprints
  are the next review's `:known_fingerprints`.

**Models**

- `Provider`: `id` (as `Tackle.Lib.LLM.Provider` ids: lowercase, hyphens;
  for example `openrouter`, `openai-codex`), `adapter` (an atom attribute
  constrained to `:openrouter | :codex`, mapped in code to
  `Tackle.Plugins.OpenRouter` / `Tackle.Plugins.Codex`; never a module name
  from input), `settings` map (passed as the adapter's provider settings, for
  example OpenRouter's `"provider_routing"`), encrypted `credentials` map
  (opaque to us), `enabled`.
- `ReviewDefaults` (one row): the model reference per stage (`detector`,
  `verifier`, `scorer`, for example `"openrouter/<vendor>/<model>"` or
  `"openai-codex/<model>"`) and thinking levels. **Required**: reviews do
  not run, and say why, until the detector and verifier models are set and
  resolve against the enabled providers. There is no implicit default model.

**Accounts**

- `User`: `forge`, `external_id`, `login`, `name`, `admin` flag. Created on
  first sign-in by a member of an installed organisation.

## 7. Components

### 7.1 Forge contract

`Tackle.Web.Forge` behaviour, so nothing outside a forge module knows a
forge's API. Only `Forge.GitHub` is implemented for the MVP; the behaviour
exists so a later Gitea module does not touch the rest of the app.

- `verify_webhook(conn_or_raw, headers, forge_app)` → `{:ok, event}` with
  type, delivery id, and decoded payload, or an error. GitHub:
  `X-Hub-Signature-256` HMAC-SHA256 over the raw body, compared in constant
  time (`Plug.Crypto.secure_compare/2`). `Plug.Parsers` consumes the body,
  so the webhook route keeps the raw bytes: a `:body_reader` that stores
  them for that path only, or the route placed before the parsers. Bound
  the body size (GitHub caps payloads at 25 MB).
- `pull_request(installation, repo, number)` → title, author, base/head refs
  and SHAs, fork flag, state.
- `can_trigger?(installation, repo, login)` → write access or higher.
- `clone_auth(installation, repo)` → clone URL and a short-lived credential.
- `post_review(installation, repo, number, head_sha, body, comments)` →
  the forge's review id.
- `find_review(installation, repo, number, marker)` → the id of an
  existing review by the app whose body contains `marker`, for idempotent
  posting (§7.5.1).
- `bot_login(forge_app)` → the login the app comments as. GitHub:
  `"<slug>[bot]"`, with the slug from `GET /app`, cached in memory. Not
  needed to ignore the app's own comments (§7.7); add it with posting
  (phase 5) only if `find_review` needs it.
- `feedback(installation, repo, number)` → resolved threads, replies, and
  reactions on our comments (phase 7).
- Sign-in (phase 6): `authorize_url(forge_app, state, redirect_uri)`,
  `sign_in(forge_app, code, redirect_uri)` → the account (id, login, name),
  and `member?(forge_app, installation, user)` (§7.6).

Phase 2 implemented `verify_webhook/3`, `pull_request/4`, and
`can_trigger?/4` (the forge app is the first argument of the API calls) in
`Tackle.Web.Forge`, with `Tackle.Web.Forge.Event` as the forge-neutral
form of a delivery; the other callbacks are added with their phases. An
event about a repository also records its installation when it is new:
a GitHub App installation belongs to one account, which owns every
repository it covers, so the repository's owner is the installation's
account.

**GitHub implementation**: a GitHub App installed on the company
organisation. App JWT (RS256, `iat`/`exp` ≤ 10 minutes, `iss` = app id)
signed with `:public_key` from the private key; installation access tokens
from `POST /app/installations/{id}/access_tokens`, cached in memory until
shortly before expiry, never written to disk or the database, never passed
to a jail. Use `req`; test with `Req.Test` stubs.

**App permissions** (checked against GitHub's REST and webhook
documentation). On GitHub every pull request is also an issue: comments in a
pull request's conversation are issue comments, delivered as `issue_comment`,
which a GitHub App only receives with the "Issues" permission, even with full
"Pull requests" access. Line comments on the diff are a separate kind
(`pull_request_review_comment`).

| Permission | Level | Why |
|---|---|---|
| Metadata (repository) | read | always granted; covers "Get repository permissions for a user", the write-access check for a command's author |
| Contents (repository) | read | clone and fetch the repository and pull request refs |
| Pull requests (repository) | write | read pull requests; "Create a review for a pull request" requires write; `pull_request`, `pull_request_review_comment`, and `pull_request_review_thread` events |
| Issues (repository) | read | only to receive `issue_comment`, the `/tackle review` command |
| Members (organisation) | read | "Check organization membership for a user" at sign-in |

Webhook events to subscribe to: `pull_request`, `issue_comment`, and later
`pull_request_review_thread` (phase 6). `installation` and
`installation_repositories` are delivered without a permission.

### 7.2 Providers and credentials

`Tackle.Web.CredentialStore` implements `Tackle.Lib.CredentialStore`
(`fetch/2`, `put/3`, `delete/2`, keyed by provider id) on the `Provider`
resource's encrypted `credentials`. Adapters receive the handle in their LLM
options as `:credential_store`. Providers are built with
`Tackle.Lib.LLM.Provider.new/3` from the enabled rows and passed to the
agent backend and to `Tackle.Review.Settings.new/2`.

**OpenRouter** (`Tackle.Plugins.OpenRouter`): credentials are
`%{"api_key" => key}`, entered through a `:set_credentials` action. The
adapter falls back to the `OPENROUTER_API_KEY` environment variable for the
default `openrouter` provider when nothing is stored; the service must not
set it, so the database stays the only source.

**OpenAI Codex** (`Tackle.Plugins.Codex`): a ChatGPT subscription login.
Use the **device-code flow**
(`Tackle.Plugins.Codex.OAuth.request_device_code/1`, then
`complete_device_code/2`), not the redirect flow, whose redirect URI is
`http://localhost:1455/auth/callback`. A small LiveView page (AshAdmin
cannot do this) shows the user code and verification URL, waits for
completion in a task, and stores the returned credentials. The adapter
refreshes expired tokens itself and writes them back with `put/3`. It
serialises refreshes with a `:global` lock keyed on the store handle and the
provider id, and re-reads the credentials inside the lock. Therefore:

- use one **stable handle** for all runs,
  `{Tackle.Web.CredentialStore, :default}`, never a per-run reference, or
  the lock does not serialise concurrent reviews and a rotated refresh token
  can be lost (phase 7 makes it one stable handle per provider owner,
  `{Tackle.Web.CredentialStore, owner_id}`, §7.12);
- `fetch/2` reads the database every time (no cache), and `put/3` writes in
  a transaction.

The Cloak key comes from the environment (`TACKLE_WEB_CLOAK_KEY`, base64,
32 bytes) set by the NixOS module's environment file; support Cloak's key
rotation (a list of ciphers with tags) from the start. (Implemented in
`Tackle.Web.Vault`: retired keys in `TACKLE_WEB_CLOAK_RETIRED_KEYS`, tags
from key fingerprints. Cloak 1.1 returns `{:ok, :error}` for an AES-GCM
ciphertext that fails authentication; the vault turns that into an error,
which AshCloak's `decrypt!` then raises.)

Phase 3 implements these resources under `Tackle.Web.Models`, with a stable
`CredentialStore.handle/0`. `Models.enabled_providers/0` builds the enabled
instances without secrets; `Models.resolve_settings/2` merges repository
models/thinking over `ReviewDefaults` per stage and requires detector/verifier
models. Both saved settings and runtime resolution validate against enabled
providers. There is no implicit model. `Models.CodexDevice.request/2` and
`complete/2` implement the trusted device-login service. Phase 6 mounts
`CodexLoginLive` at `/codex-login` behind the admin guards (§7.6). See the app
README for console configuration.

### 7.3 Agent backend

`Tackle.Web.AgentBackend` implements `Tackle.Runtime.AgentBackend`:

- Spec config: a struct with providers, the selected `Tackle.Lib.LLM`
  selection and model reference, tools, system prompt, context, adapter
  options (including `:credential_store`), and step limit.
- One process per agent that runs one `Tackle.Lib.run/3` turn at a time in a
  task, forwards the loop's events to subscribers as
  `{:tackle_runtime_event, event}`, reports a delegated run's outcome to
  `context.terminal`, cancels through a `Tackle.Lib.Cancellation` signal on
  `:cancel` and `{:runtime_cancel, reason}`, and answers `:snapshot` with
  `%{agent_state: state}`.
- `prepare_child/2`, `select_model/2`, `model_ref/1`, and the review
  callbacks `configure/2`, `describe/1`, `llm/1`, `outcome/2`.
- Nothing is persisted for review runs; the review result is what is kept.

**Reference implementation**: `packages/tackle_review/test/support/backend.ex`
is exactly this backend, minus credentials, and the review test suite runs
whole reviews on it. Start from it; the harness's
`Tackle.Runtime.RootBackend` shows the same callbacks on `%Tackle.Config{}`.
Test the app's backend with the same scripted-adapter approach as
`packages/tackle_review/test/tackle/review_test.exs`.

Implemented in phase 3: `AgentBackend.config/1` accepts explicit providers,
model, tools, context, adapter options, thinking and `max_steps`. It installs
the stable database credential handle, forwards streaming events, monitors
subscribers, and owns a linked turn task which is stopped with the agent.
Tests exercise a full detector/verifier/scorer review plus inheritance,
cancellation, step limits, provider/task failures and scope cleanup.

### 7.4 Checkouts

`Tackle.Web.Checkout`, all Git through `System.cmd("git", ...)` with a
clean environment: `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`,
`GIT_TERMINAL_PROMPT=0`, `-c core.hooksPath=/dev/null`,
`-c protocol.file.allow=never`.

**Credentials** go into the command's environment, never onto its command
line (any local user can read `/proc/<pid>/cmdline`, but not another
user's environment), into a remote URL, or into the repository's config:
`GIT_CONFIG_COUNT=1`,
`GIT_CONFIG_KEY_0=http.https://github.com/.extraHeader`,
`GIT_CONFIG_VALUE_0=Authorization: Basic <base64("x-access-token:" <> token)>`
(GitHub's form for installation tokens over HTTPS). Only commands that
talk to the remote get them; tests assert that no argument contains the
token.

1. One bare clone per repository under `<state>/repos/<installation>/<repo>`,
   with full history: a shallow clone can lack the merge base the change
   needs.
2. Fetch the base branch and the PR head (`refs/pull/N/head` on GitHub) to
   the requested SHAs.
3. A detached worktree of `head_sha` under `<state>/worktrees/<request id>`,
   removed after the run (also on failure; at start, sweep leftover
   worktrees and run `git worktree prune`).
4. The change: `Tackle.Review.Change.load(cwd: worktree, workspace:
   state_dir, range: "#{base_sha}...#{head_sha}")`.

**Workspace for `Change.load`.** `Tackle.Review.Confinement` refuses a
repository whose working tree, Git directory, or common directory lies
outside `:workspace`. A worktree of a bare clone has its Git directory in
the clone (`<state>/repos/.../worktrees/<id>`), so passing the worktree is
refused with `{:outside_workspace, ...}`; pass the state directory, which
contains both. Confinement compares paths as given, so resolve the state
directory (no symbolic links) once at start and build every path from it.

**Concurrency.** Steps 1 to 3 and the worktree removal change the shared
bare clone (refs, `worktrees/`, Git's lock files), so two reviews of one
repository must not run them at once. Hold a per-repository lock around
them. A Postgres advisory lock would hold a pooled database connection for
the length of a fetch, so use a lock outside the database instead:
`:global.trans({{Checkout, repo_id}, self()}, fn -> ... end)` (with
`Checkout` aliased to `Tackle.Web.Checkout`), which also covers more than one
connected node. The outer tuple separates the shared lock identity from the
requesting process identity; omitting it does not serialize callers correctly.
The review itself runs outside the lock: a later
fetch only adds objects and moves refs, which does not change a worktree at
a fixed SHA.

**Host Git and the jail.** The host runs Git on the clone and the worktree
again after a review (the next fetch, the worktree removal). That is only
safe because the jail cannot write to either (§7.8): Git honours
configuration, hooks, alternates, and worktree metadata found there, so a
writable mount would let jailed code reach the server through host Git.

### 7.5 Review job

**Phases 4–5 implementation:** `ReviewJob` runs steps 1–7, tears down review
resources, then posts the stored result (step 8). The trigger includes reviewed
requests; that branch only posts, without model calls, checkout or budget
admission. Immediate enqueue and the cron safety net are wired up. The timeout is
20 minutes, max attempts three, Lifeline rescue after 30 minutes. See the app
README's [review jobs](../apps/tackle_web/README.md#review-jobs-and-stored-results-phase-4)
for public entry points and failure/lifecycle semantics.

`ReviewRequest`'s AshOban trigger runs the `:run` action, which calls
`Tackle.Web.ReviewJob.run/1` (plain Elixir). Oban queue `reviews` with
concurrency 1 to 2, a timeout, and limited retries (`:failed` with the error
after the last attempt). Add `Oban.Plugins.Lifeline` so jobs orphaned by a
crash or restart are retried.

Enqueueing: AshOban schedules triggers from a cron scheduler that polls
(by default every minute). After upserting a request, call
`AshOban.run_trigger/2` so the review starts at once; the scheduler stays
as the safety net.

**One job per request at a time.** The immediate enqueue, the scheduler,
and Lifeline can each enqueue a job for the same request, so:

- make the trigger's jobs unique on the request id across the `available`,
  `scheduled`, `executing`, and `retryable` states;
- the job claims the request before any work: a transaction that takes a
  Postgres advisory lock on the request id (`pg_try_advisory_xact_lock`)
  and re-reads the status; a job that cannot take the lock, or finds the
  request already claimed by a live attempt, returns without work. Record
  the claiming attempt on the request, so a crashed attempt's `:running` is
  told apart from a live one;
- Lifeline cannot tell an orphaned job from a slow one: its `rescue_after`
  must be longer than the review job's timeout, or a long review is started
  a second time while it still runs.

Posting relies on this too: the marker lookup in §7.5.1 is not atomic, and
only the claim keeps two attempts from both finding no review and both
posting.

The job starts from the request's current status, so retries and stale
jobs are safe:

- `:pending` or `:running` (an earlier attempt crashed or timed out): run
  steps 1–8, with a fresh worktree for reviewing;
- `:reviewed`: only post the stored run (step 8);
- `:posted`, `:failed`, `:skipped`: return without work. A request
  superseded by a newer head (§7.7) may still have a job enqueued; this is
  where it ends.

**Crash/timeout fencing (implemented).** The normal final-error action sets
`:failed`, but an Oban timeout or process death bypasses it. A subsequent
scheduler job checks the recorded owner in `oban_jobs`: discarded, cancelled,
completed-without-a-result or pruned/missing owners fail the request without
starting another review cycle. An executing same attempt is a no-op; only a
larger attempt of the same owner job may reclaim a running request. Writes
check the owner and actual executing attempt under short row locks. Runtime
scopes do not follow an Oban caller automatically: the per-run lifecycle owner
monitors that caller, serializes acquisition, and holds a preallocated scope
reference before starting it, then tears down scope → jail → checkout on death.
Startup/periodic sweeps conservatively preserve live leases and executing jobs.

1. Check the repository is enabled and within its daily token budget
   (sum of today's `ReviewRun.usage`); else `:skipped` with a reason. Set
   `:running`.
2. Checkout (§7.4).
3. Rules from the **base** commit, so a pull request cannot change the
   rules it is reviewed against:
   `{:ok, files} = Tackle.Review.Rules.read_tree(worktree_or_clone, base_sha)`,
   `Rules.load([{:project, files}], builtin_rules: ...)`; turn load warnings
   into strings for `:warnings`.
4. Settings: validate again at run time, `Settings.from_json/1` and then
   `Tackle.Review.Settings.new(opts, providers)` against the providers
   enabled **now**, merged with `ReviewDefaults` by the precedence of §6.
   Settings were valid when saved, but a provider disabled or a default
   changed since then must fail the request with a readable reason, not
   crash the job.
5. A scope on `Tackle.Web.AgentBackend`: a root agent that never runs a
   turn (allow delegation), and the two stage profiles built from
   `Tackle.Review.Stages.detector/0` and `verifier/0`: tools
   `Tackle.Tools.Read`, `Tackle.Tools.Bash`, and
   `Tackle.Review.Tools.ReportFindings` / `ReportVerdict`; context
   `%{cwd: worktree, executor: jailed_executor}`; step limit from
   `max_steps`. Each stage profile gets its resolved model, so nothing
   depends on inheritance; the root still gets a valid model (the
   verifier's), because the scorer and any inheriting profile read the
   requester's.
6. `Tackle.Review.run(change, requester: root, profiles: ..., rules: ...,
   settings: ..., profile: ..., known_fingerprints: dismissed,
   warnings: ..., on_event: ...)`; phase 4 stores running/reviewed/error
   progress. Finer-grained UI event progress remains later interface work.
7. In one transaction, store the `ReviewRun` and `Finding`s (shown,
   rejected, and `Result.hidden/1`) and set `:reviewed`. Stop the scope and
   remove the worktree (under the repository lock, §7.4).
8. Post (§7.5.1), store the forge's review id, and set `:posted`.

Storing before posting keeps a retry from reviewing (and paying for) the
same head twice; the posting step is idempotent on its own (§7.5.1).

#### 7.5.1 Posting

`Tackle.Web.Posting` builds one review (`event: COMMENT`):

- a finding whose location lies on lines of the diff becomes a line comment
  (`path`, `side` `RIGHT` for `:new`/`LEFT` for `:old`, `line` = end line,
  `start_line` when the range spans lines; GitHub requires both ends in the
  same hunk, otherwise comment on the end line only);
- other findings go into the review body;
- the body leads with the verdict and counts, lists blocking findings
  first, and says which profile and how many units were reviewed;
- a fingerprint already posted on this pull request (any earlier run) is not
  posted again; mention it as still present in the body instead.

**Implemented in phase 5:** `Posting` orchestrates forge calls and
`Posting.Format` owns pure formatting. The sanitized payload is frozen before
POST in `ReviewRun.summary["posting"]`; that entry also retains posted
fingerprints, review ID and comment IDs across request reruns. Only entries
actually included (body or inline) count for deduplication. Diff files come from
the forge, with matching base/head reads before and after; mismatches fall back
to body-only posting. No checkout is needed for retries. Posting is additionally
serialized per PR across connected nodes so different heads cannot race
fingerprint lookup; disconnected hosts sharing a database are unsupported.
Unresolved prepared postings are reconciled before later runs; an absent marker
blocks later posting until retry or explicit paid rerun abandons that intent.
GitHub has no atomic idempotency-key API: recovery assumes accepted reviews
are visible to later marker reads.

Posting errors preserve `:reviewed` for the owning job's retries; exhaustion or
cancellation becomes `:failed` with a fixed posting error. `Posting.retry/1`
restores `:reviewed` and enqueues only posting. A same-profile command after a
posting failure also retries posting; explicit rerun/different-profile commands
still request a paid review. Disabled integrations fail posting without losing
stored results. Deployment makes existing reviewed requests scheduler-eligible.
See the app README's [posting guide](../apps/tackle_web/README.md#forge-posting-phase-5).

**Idempotent posting.** The body carries a hidden marker,
`<!-- tackle-review:<run id> -->` (the run's, not the request's: a request
that runs again posts a new review). Before posting, `find_review/5`
looks for a review by the app with that marker; when one exists (an earlier
attempt posted, then failed before recording it, or the response was lost),
record its id and set `:posted` instead of posting again.

**Model output is untrusted.** Finding text was written by a model that
read the pull request, so a prompt injection can choose what the bot posts
under its name. The formatter therefore:

- neutralises `@` mentions (users and teams) and closing keywords such as
  `fixes #123`, so a finding cannot notify people or close issues;
- escapes HTML and puts code (excerpts, suggestions) in fenced blocks whose
  fence is longer than any backtick run inside;
- caps each finding's text and the number of line comments (the rest are
  listed in the body), and keeps the body under GitHub's 65,536 characters,
  saying what was cut.

Keep the comment text format in one module, separate from the GitHub API
calls, so a later forge reuses it.

### 7.6 Sign-in and authorisation

Our own GitHub OAuth web flow through the same GitHub App's client id and
secret: `/auth/github` redirects with a random `state` stored in the
session; `/auth/github/callback` checks `state`, exchanges the code with
`req`, reads `/user`, and checks membership of an installed organisation
(`GET /orgs/{org}/members/{login}` with an installation token). Then
**renew the session** (`configure_session(renew: true)`) before storing the
user id. Logout drops the session. All admin pages require a signed-in
user; settings changes require `admin` (the first user, or set in the
console; phase 6b replaces both with the setup claim and the admin
interface, §7.11). Protect forms with Phoenix's CSRF tokens.

**Implemented in phase 6** (`Tackle.Web.SignIn`, `AuthController`, `Auth`,
`Accounts.User`). Membership comes from the forge for every sign-in: an
organisation member (installation token), or the user account an installation
is on, compared by account id from `GET /app/installations/{id}` rather than
by the stored login; only active installations count. The user's access token
is revoked after `/user` is read. The session holds the user id and sign-in
time (seven days); the user is re-read on every request and mount. Phase 6b
replaced "the first user is admin" and console-only granting: the first admin
claims it from the unlocked setup session, and admins manage admins (§7.11).
Phase 7 also admits installation owners and grantees, checked in the database
before asking the forge, and scopes every read to them (§7.12).

### 7.7 Triggers and limits

**Webhook handling stays short**: verify the signature, upsert the
installation, repository, or request, enqueue (§7.5), and answer 2xx.
GitHub waits 10 seconds and does not redeliver a failed delivery by
itself, so no forge or model calls happen in the request; pull request
details the payload lacks are fetched by the job.

Two ways to start a review, as other review bots offer them:

- **Command.** `issue_comment` (`created`) on a pull request (the issue
  payload has a `pull_request` key) whose body starts with `/tackle review`,
  optionally followed by a profile (`quiet`, `default`, `assertive`), from a
  user with write access → upsert a `ReviewRequest` (`trigger: :command`)
  for the pull request's current head. Works on any enabled repository,
  whatever its `auto_review`, and on forks and drafts. Ignore edited
  comments and comments by bots (the author's type), which covers the
  app's own without an API call. The comment carries no head SHA, and
  the write-access check is an API call, so the webhook only queues a
  `Tackle.Web.Triggers.CommandJob` (Oban queue `forge`), which checks the
  permission, reads the pull request's current head, and makes the
  request.
- **Automatic review of new pull requests.** With `auto_review: :on_open`,
  `pull_request` `opened`, `reopened`, and `ready_for_review` → a request
  (`trigger: :opened`). With `:on_open_and_push`, also `synchronize` (new
  commits) → a request (`trigger: :pushed`) for the new head; findings
  already posted on the pull request are not posted again (§7.5.1), so a
  push review only adds what is new. Drafts are skipped unless
  `auto_review_drafts`, and reviewed when they become ready. Fork heads are
  skipped unless `auto_review_forks`.

Turning on "review every pull request" for the organisation:
`review_new_repositories` and `default_auto_review: :on_open` on the
installation, plus a bulk action that applies them to the existing
repositories.

Limits:

- the uniqueness of (repository, pull request, head SHA) makes redelivered
  webhooks and a command after an automatic review of the same head no-ops.
  Decided in phase 2: a head's request runs again when a command asks for
  it after it failed or was skipped, or after it was posted with a
  different profile, and when an automatic trigger (a pull request
  reopened) finds it skipped;
- closing a pull request skips its pending requests;
- a newer head supersedes pending requests for older heads of the same pull
  request (mark them `:skipped`), so a burst of pushes reviews only the last;
  their already enqueued jobs end at the status check (§7.5). A review
  already running for an older head finishes;
- a daily token budget per repository; Oban concurrency caps parallel
  reviews.

### 7.8 Jail for untrusted code

Pull requests are untrusted, including prompt injection aimed at the review
agents. The threat to defend against is a pull request that gets code run
in the jail (an agent told to run it through `bash`) and uses it to
compromise the server or later reviews. The review agents' `read` and
`bash` run through `Tackle.Executor.Jailed` with a `Tackle.Exec.Client` on
a dedicated launcher, `tackle-review-jail`, a variant of
`nix/packages/exec-jail.nix`:

- **no network** (the existing `exec-jail` always keeps the network
  namespace);
- **no `/nix` mount or Nix daemon** beyond the tool closure:
  `enableNix = false`, an option that already exists;
- **nothing writable from the host**: the worktree and every Git
  directory the launcher mounts are read-only (below);
- no state directory beyond the worktree's Git data, no credentials, no
  service environment; `GIT_OPTIONAL_LOCKS=0` in the jail, so read-only
  commands such as `git status` do not try to write the index. A private
  `/tmp` stays writable for tools that need scratch space; it is discarded
  with the jail.

**Read-only Git mounts.** The worktree is a linked worktree of the bare
clone, and the launcher mounts the Git data it needs through
`nix/packages/jail-git.sh`. For Herdr worktrees that script mounts the
worktree's Git directory and the common directory's `objects`, `refs`,
`logs/refs`, `rr-cache`, and `reftable` **writable**, and creates missing
`logs/refs` and `config.worktree` on the host, so commits work in the jail.
Here the common directory is the bare clone that later reviews of the
repository and the host's own Git read (§7.4). Writable, it would let
jailed code plant objects, refs, symbolic refs, alternates, or worktree
metadata that outlive the run: poisoning later reviews' code and rules, or
reaching the server through host Git. With `readOnlyWorkspace`, the
launcher therefore:

- binds the worktree, the worktree's Git directory, and the whole common
  directory with `--ro-bind`, and binds nothing writable;
- creates nothing on the host (no `mkdir`, no empty `config.worktree`);
  entries that do not exist are not mounted;
- keeps every existing check (pointer validation, no symbolic links, no
  planted `commondir`), which still matter because they run on the host.

The bare clone holds the repository's other refs, including other pull
requests' heads (`refs/pull/*`); anyone with read access to the repository
can see those on the forge, so mounting them is accepted.

Add options to `exec-jail.nix` (`network ? true`, `readOnlyWorkspace ?
false`, passed through to `jail-git.sh`) rather than copying it, and a
package `tackle-review-jail`. Bubblewrap needs unprivileged user
namespaces: the NixOS module's systemd hardening must not set
`RestrictNamespaces` to forbid `user`. One exec client per review run,
started with the worktree as its working directory; see
`apps/tackle_cli/lib/tackle_cli/jail.ex` for how the CLI starts one and
fails closed. Never fall back to the local executor.

Like the CLI, check the jail before the first run and fail closed: from
inside it, writing to the worktree, to the clone's `objects` and `refs`,
and to the worktree's Git directory must fail, a network connection must
fail, and the state directory outside the clone must not be visible. A
launcher test (beside the existing `nix/tests/`) asserts the same.

### 7.9 Web interface

**AshAdmin**, mounted at `/admin` (`ash_admin "/admin"` in the router),
covers managing the resources: installations and repositories (enable,
automatic review, profile, settings, daily budget), providers, review
requests and runs with their findings, and finding outcomes. Configure
each resource's `admin` section (actor, table columns, which actions
appear), and expose only the actions an operator should use.

Rules for it:

- The `/admin` scope sits behind the sign-in pipeline and requires an
  `admin` user; AshAdmin runs actions as that user (set the actor), and the
  resources' policies decide what is allowed.
- Every secret attribute (forge private key, webhook and client secrets,
  provider credentials) is `sensitive?: true` and never listed in
  `show_sensitive_fields`, so AshAdmin redacts it. Secrets are written
  through dedicated actions (for example `:set_credentials`) that accept
  them as arguments and never read them back.
- Validation lives in the resources' actions (settings through
  `Tackle.Review.Settings.from_json/1` and `new/2`, provider ids and adapter
  allowlist), so AshAdmin and any later page enforce the same rules.

Custom LiveView pages only where AshAdmin does not fit: the sign-in page,
the Codex device-code login (§7.2), and, if useful, a review run view that
shows its findings next to the diff lines and the run's cost. Use AshPhoenix
forms there.

**Implemented in phase 6.** Every domain uses `authorize :when_requested`:
calls with an actor (the web interface) are authorised, calls without one
are trusted server code; AshOban's authorised calls pass through
`AshOban.Checks.AshObanInteraction`. Policies allow reads to signed-in users
and only the listed admin actions to admins, re-reading the user
(`Accounts.Check`); internal actions are refused to every actor. AshAdmin
derives its actor and "authorizing" flag from browser-controlled cookies,
connect parameters, and events, so its live session runs a hook
(`Auth.pin_admin_actor/2`) that pins the signed-in admin with authorisation on
before every `handle_params` and event and drops the actor/authorisation/tenant
events. AshCloak's `on_decrypt` refuses decryption with an actor. The forge
app is registered by setup's manifest flow (§7.11), never typed into a form;
reruns and posting retries are not admin actions (installation owners
request them on the user pages, phase 8, and the console can). Policies need a SAT
solver: `simple_sat` (pure Elixir).

### 7.10 Deployment

- `nix/packages/tackle-web.nix`: a Mix release of `apps/tackle_web`
  (dependencies through `deps_nix` like the CLI: add a `deps.nix` alias in
  its `mix.exs` that writes `nix/tackle-web-deps.nix`).
- `nixosModules.tackle-web` in `flake.nix`: `services.tackle-web` with
  `enable`, `package`, `listenAddress`/`port`, `stateDir`
  (`/var/lib/tackle-web`), `environmentFile` (secrets:
  `SECRET_KEY_BASE`, `TACKLE_WEB_CLOAK_KEY`, `DATABASE_URL` if not local),
  `reviewJail` (the launcher package), a dedicated user, PostgreSQL through
  `services.postgresql` (`ensureDatabases`/`ensureUsers`, peer
  authentication over the Unix socket), and migrations on start
  (`Tackle.Web.Release.migrate/0`). Forge app secrets are entered in the UI
  and stored encrypted, not in Nix. (Phase 1b implemented all of this
  except `reviewJail`, which arrives with the jail in phase 4, and added
  `url`, `homeDir`, and `database.createLocally`. The release runs without
  Erlang distribution. Dependencies are compiled with the app's
  `config/ash.exs`, because Ash reads it at compile time and a release
  refuses to boot when compile-time and runtime values differ.)
- TLS ends at the operator's reverse proxy. When the sign-in pages land
  (phase 6), production sets `force_ssl` with
  `rewrite_on: [:x_forwarded_proto]` and HSTS for an `https`
  `TACKLE_WEB_URL`, and session cookies are `secure`. (Implemented in
  phase 6 as runtime settings read by the endpoint, since Phoenix's
  `:force_ssl` is compile-time; `/health` and loopback hosts are excluded.)
- The service user's `HOME` must not be the state directory or any other
  ancestor of `<state>/worktrees` or `<state>/repos`: jail.nix's base
  permissions mount `--tmpfs ~`, which can cover the worktree and clone
  mounts beneath it, and `exec-jail.nix` refuses a workspace or common Git
  directory that contains the home directory. The home must be writable,
  as jail.nix keeps its runtime data in `~/.local/share/jail.nix`. Use a
  separate directory such as `/var/lib/tackle-web-home`, and cover it in
  the VM test.
- A NixOS VM test (`nix/tests/`) that starts the service with Postgres and
  checks the health endpoint, when phase 1b lands.
- CI: Woodpecker runs on its local backend without service containers, so
  the `tackle_web` step starts its own throwaway Postgres (`initdb` and
  `pg_ctl` on a Unix socket in a temporary directory) and stops it at the
  end, like the dev shell script.

### 7.11 Web-only setup (phase 6b)

**Goal:** after deployment (§7.10: the NixOS module, `SECRET_KEY_BASE`,
`TACKLE_WEB_CLOAK_KEY`, `TACKLE_WEB_URL`), everything is done in the browser:
creating and storing the GitHub App, installing it, recording installations
and repositories, the first admin, and granting admin to others. No secret is
copied by hand. The release commands (`configure_github_app/0`,
`set_admin/2`) stay, for recovery only.

Decisions (taken after phase 6; implemented in phase 6b):

- **Bootstrap with a logged setup token.** Setup is *incomplete* while no
  GitHub App is stored or no user is an admin. While it is incomplete, the
  server generates a random token at boot (`Tackle.Web.Setup`), keeps it in
  memory only (never in the database or a file), and logs it with the setup
  URL (`journalctl -u tackle-web`); a restart makes a new one. `/setup` asks
  for it (a POST, compared in constant time) and marks that browser's session
  as unlocked for a bounded time. Without the token, nobody who reaches a
  fresh server can register their own App and become its admin. When setup
  is complete the token stops working and `/setup` leads to the start page.
- **The setup browser becomes the first admin.** Signing in from an unlocked
  session claims admin, under the advisory lock, only while no admin exists.
  This replaces "the first user to sign in becomes admin" (§7.6), which let
  any organisation member race the operator.
- **GitHub App manifest flow.** From the unlocked session, `/setup` builds a
  manifest (name, homepage, webhook URL and events, callback URL
  `/auth/github/callback`, redirect URL `/setup/github/callback`, setup URL
  `/setup/github/installed`, `public: false` (`true` from phase 7, §7.12),
  the §7.1 permissions) and posts
  it to `https://github.com/settings/apps/new` or
  `https://github.com/organizations/<org>/settings/apps/new` with a one-time
  `state` from the session. GitHub creates the App and redirects back with a
  code; `POST /app-manifests/{code}/conversions` (unauthenticated, within one
  hour) returns the App id, client id and secret, webhook secret, and private
  key, which are stored encrypted (a create that fails if an App exists). The
  browser then goes to the App's installation page. All of this is behind
  `Tackle.Web.Forge` callbacks.
- **Webhooks on a loopback URL.** GitHub cannot deliver to `localhost`, so a
  `TACKLE_WEB_URL` on a loopback host (development) registers the App
  without a webhook and with a locally generated webhook secret; installations
  and repositories then come from the setup URL and the sync below. A tunnel
  URL as `TACKLE_WEB_URL` gets webhooks as in production.
- **Installations without webhooks.** The setup URL's `installation_id` can
  be forged, so it is only a hint: the installation is confirmed with the
  App's JWT (`GET /app/installations/{id}`) and recorded with its
  repositories (`GET /installation/repositories`), with the same upsert rules
  as webhooks, and only for an unlocked setup session or a signed-in admin.
  A **Sync from GitHub** button (admins) reconciles everything: every
  installation of the App (`GET /app/installations`) with its status and
  repositories; installations GitHub no longer lists become `:removed` and
  repositories no longer listed are deactivated. It covers missed webhooks.
- **Admins manage admins.** `User.set_admin` is an admin action in the admin
  interface; it refuses to remove the last admin.

Not in phase 6b: replacing or rotating the App's secrets from the browser
(delete and re-run setup, or the release command), and Gitea (§11).

### 7.12 Ownership and access (phase 7)

**Goal:** every installation belongs to the user who installed the App.
That owner decides which other users may see its repositories and reviews,
configures them, and pays for their reviews with their own providers and
review defaults. Normal users install the App on their own accounts
themselves. Admins keep AshAdmin as the operator's tool and see everything
there. Until phase 7, every signed-in user reads every repository and review,
and providers and review defaults are shared by the whole server.

Decisions:

- **Installing is self-service.** Any signed-in user gets an "Install on
  GitHub" link (`/setup/github/install`, today admin-only). GitHub only lets
  other accounts install an App that is **public**: new registrations use
  `public: true` in the manifest (§7.11), and an existing App is switched in
  its GitHub settings (README). The setup URL (`/setup/github/installed`)
  syncs the installation for any signed-in user. As now, the sync confirms
  the id with the App's JWT; it never assigns an owner from the browser.
- **The owner is the GitHub user who installed the App.** The
  `installation` `created` webhook is signed by GitHub, and its `sender` is
  stored as `Installation.owner_external_id` (the forge's user id) with
  `owner_login` for display. Matching is by forge user id, so it survives
  renames and works before the owner first signs in. For an installation on
  a user account, the account itself is the owner, and syncs set that from
  `GET /app/installations/{id}` (the account's type and id). For an
  organisation, GitHub's API does not say who installed it, so syncs never
  set or change the owner there. An organisation installation without an
  owner (missed webhooks, a loopback development URL, or recorded before
  phase 7) is visible only to admins and runs no reviews until an admin
  sets its owner in AshAdmin (`Installation.set_owner`, choosing a user).
  Reinstalling makes a new installation id, and so a new owner.
- **Access grants.** A new resource, `Forges.Access`: `installation`,
  `repository` (nil for every repository of the installation, including
  later ones), `forge_user_id`, `login` (as entered, for display), and
  `granted_by` (a user). It has one unique index per scope: whole
  installation, or one repository. Owners add a grant by GitHub login; a new
  `Tackle.Web.Forge` callback resolves the login to the user id
  (`GET /users/{login}`). A grant gives read access only. Deleting it
  revokes access at once, because policies are checked on every read and
  LiveViews re-read on every event.
- **Who may do what.**

  | Actor | Installations, repositories, reviews | Settings | Grants | Providers, review defaults |
  |---|---|---|---|---|
  | owner | read their installations | `Repository.configure`, `Installation.set_defaults` | create, delete, read | their own |
  | grantee | read granted repositories and their requests, runs, findings | none | read their own | their own |
  | other signed-in user | nothing | none | none | their own |
  | admin (AshAdmin) | read everything | as now, plus `set_owner` | read, delete | read rows, never secrets |

  Users read only themselves; admins read every user. Grant lists show the
  stored login, not other users' rows. Read policies use filter checks
  (one shared expression for "owns or is granted", following
  `repository.installation`), combined with `Accounts.Check` so that a user
  deleted since the page loaded is still refused.
- **Providers belong to users.** `Provider` gets a UUID primary key, a
  required `owner` (a user), and `name`, which is the `Tackle.Lib.LLM.Provider`
  id used in model references (`openrouter/...`). Names are unique per owner,
  so every user can have an `openrouter` provider. `ReviewDefaults` becomes
  one row per user. A repository's reviews resolve against the enabled
  providers and the defaults of its installation's owner only:
  `Models.enabled_providers(owner)` and `Models.resolve_settings(owner,
  settings, profile)`. `Repository.ValidateSettings` validates against those
  same providers. A request whose installation has no owner fails with a
  readable error. The credential store handle becomes
  `{Tackle.Web.CredentialStore, owner_id}`, and `fetch/2`, `put/3`, and
  `delete/2` look up by owner and name. The handle is still stable per owner,
  so Codex's refresh lock still serialises concurrent reviews (§7.2). The
  Codex device login works on the signed-in user's own providers and no
  longer needs an admin. Secret handling is unchanged: write-only actions,
  and decryption only without an actor.
- **Sign-in.** The membership rule of §7.6 stays (a member of an account
  with an active installation). Users who own an installation, or hold a
  grant on an active one, may also sign in; this is checked locally first,
  without an API call. With a public App, anyone can install it on their own
  account and so sign in. Without an owner or a grant they see only their
  own providers and defaults.
- **Migration of existing data.** Existing providers and the defaults row
  go to the oldest admin, and provider names keep the old ids, so stored
  model references keep working. Installations on user accounts get that
  account as owner. Organisation installations get the oldest admin, who
  installed them through setup. Existing users keep their admin flag.

**Implemented in phase 7.** `Forges.AccessCheck` is the shared policy filter
(owner, or owner and grantees, from an installation or a repository, through
a to-one path for requests, runs, and findings); `Forges.Access` with
`Access.Resolve` (the forge lookup, before the transaction) and
`Forges.OwnerCheck`; `Installation.record_owner` (internal, only while
unowned, through `Installation.put_owner/2` from webhooks and syncs),
`set_owner` (admins), and `owner/1`; `Accounts.ActorOwns` for providers and
defaults; `Forge.user/3`; `Auth.require_user`. The forge app record is
readable by admins only. Migration `add_ownership_and_access`.

Not in phase 7: roles above read access (letting a grantee configure or
rerun), owners transferring ownership themselves (admins can), granting
GitHub teams or collaborators automatically, admin approval of new
installations, and the user-facing pages (phase 8, §8). Until phase 8,
owners manage grants, settings, and providers through code interfaces and
tests only.

### 7.13 Feedback (phase 9)

**Goal:** what people do with the posted findings reaches tackle. A finding
someone with write access dismissed is not reported again in that
repository, and reactions show which findings people found useful.

Decisions (taken at phase 9; they replace the `FindingOutcome` sketch of §6):

- **Dismissals** (`Reviews.Dismissal`): one row per repository and
  fingerprint, with `source` (`:forge` or `:web`), `by` (a login), the pull
  request and the finding's title for display. Every review of the
  repository passes the dismissed fingerprints to `Tackle.Review.run/2` as
  `:known_fingerprints`, so they are dropped like the plan's "dismissed
  fingerprints" (§7.5 step 6).
- **Resolving a thread dismisses.** GitHub sends `pull_request_review_thread`
  (`resolved` / `unresolved`) with the thread's comments. A thread counts
  only when one of its comment ids is a comment tackle posted in that
  repository (`Finding.forge_comment_id`), never by a marker in a body that
  anyone can write. Resolving needs write access on GitHub, but a pull
  request's author can resolve threads on their own pull request too, so the
  sender's write access is checked (as for commands, §7.7) before anything
  is recorded: otherwise a pull request could hide a finding from later
  reviews by resolving it. `unresolved` by someone with write access removes
  the dismissal. The check is an API call, so the webhook only queues a
  `Tackle.Web.Feedback.Job`.
- **Reactions are counts, not decisions.** GitHub sends no webhook for
  reactions; the review comments of a pull request carry their counts
  (`GET /repos/{owner}/{repo}/pulls/{number}/comments`, `reactions`). They
  are read for pull requests with posted comments when the pull request gets
  a new head or is closed, and stored on the finding (`reactions_up`,
  `reactions_down`). Anyone who can see a public repository can react, so
  reactions never dismiss anything.
- **Dismissing in the browser.** The installation's owner dismisses or
  restores a finding on the review page (`source: :web`); grantees cannot.
**Implemented in phase 9**: `Reviews.Dismissal` (with `Dismissal.ByActor`
and the shared `Forges.OwnerCheck`), `Tackle.Web.Feedback` and
`Feedback.Job` (queue `forge`), `Forge.review_comment_reactions/4`, the
`:review_thread` event, `Finding.reactions_up`/`reactions_down` and an index
on `forge_comment_id`, and the dismiss/restore controls on the review and
repository pages. A resolve and an unresolve in quick succession are
separate jobs and may run in either order.

- Not in phase 9: marking findings fixed (a later run of the same pull
  request that no longer finds them), replies, and statistics.

The App also subscribes to `pull_request_review_thread` (new registrations;
an existing App adds the event in its GitHub settings).

## 8. Phases

Each phase ends with `mix compile --warnings-as-errors`, `mix format
--check-formatted`, `mix credo --strict`, and `mix test` passing for
`apps/tackle_web` and every package it touches; tests use fake forges
(`Req.Test`) and fake model adapters, need no network or credentials, and
use Postgres with the Ecto sandbox. Commit per phase.

1. **Skeleton**, in two commits:
   - **1a, the app.** Mix project, Phoenix endpoint and router, AshPostgres
     repo, the Cloak vault, Oban (with Lifeline), a health endpoint, the
     empty Ash domains, config for dev/test/prod (runtime config from the
     environment). Dev shell: `pkgs.postgresql` and a script to start a
     local cluster under the project directory. Pre-commit credo hook
     entry, `AGENTS.md` (commands, repo map, the Jason rule wording),
     README.
   - **1b, packaging.** Nix package (`deps.nix` alias), the NixOS module
     skeleton (§7.10, including the separate `HOME`) with the VM test, and
     the Woodpecker step with its own Postgres.
2. **Forges and webhooks.** `ForgeApp`, `Installation`, `Repository`;
   `Tackle.Web.Forge` and `Forge.GitHub` (JWT, installation tokens, webhook
   verification with the raw body, `bot_login/1`); `POST /webhooks/github`,
   which only verifies, upserts, and enqueues; installation and repository
   sync from `installation*` events (new repositories take the
   installation's defaults); the command and automatic-review rules of §7.7
   creating `ReviewRequest`s.
3. **Models and agent backend.** `Provider` and `ReviewDefaults`,
   `Tackle.Web.CredentialStore`, the OpenRouter key action and the Codex
   device-code login, `Tackle.Web.AgentBackend` with tests that run a whole
   review on it with a scripted adapter (no real provider calls).
4. **Review job.** `Checkout` (credentials in the environment, the
   per-repository lock, the state directory as the confinement workspace),
   the review jail (`exec-jail.nix` and `jail-git.sh` options,
   `tackle-review-jail`, the fail-closed check and the launcher test that
   writes and network access fail), `ReviewJob` with the AshOban trigger,
   the status-driven restart rules, and storing `ReviewRun` and `Finding`s
   before posting. **Implemented**: fenced atomic
   persistence, runtime settings revalidation, base rules, monitored acquisition/
   teardown, startup/periodic sweeps and exhausted-owner reconciliation.
5. **Posting. Implemented.** `Posting`, idempotent per run (the hidden marker)
   and per fingerprint, with the output sanitising of §7.5.1, fenced persistence
   of review/comment IDs, and posting-only retries from stored results.
6. **Interface and sign-in. Implemented.** OAuth sign-in, AshAdmin behind it
   with the resources' `admin` sections and policies (§7.9), the Codex login
   page, and the installation's "apply defaults to existing repositories"
   option (§7.7).
   - **6b. Web-only setup. Implemented** (§7.11): setup token, admin claim,
     manifest flow, setup URL and sync, admin management in the browser
     (`Tackle.Web.Setup`, `SetupController`, `ForgeSync`).
7. **Ownership and access** (§7.12). **Implemented.** `Installation` owner from the
   `installation` webhook's sender (or the user account), `set_owner`,
   `Forges.Access` grants with a forge login lookup, owner/grantee/admin
   policies on every forge and review resource, user-owned `Provider`s and
   per-user `ReviewDefaults` used through the installation's owner, the
   per-owner credential store handle, self-service install and Codex login,
   the extended sign-in check, and the data migration. Tests cover each role's
   reads and writes, through both code interfaces and AshAdmin's pinned actor.
8. **User frontend.** LiveView pages with the tackle logo
   (`docs/assets/tackle-logo.svg`) and a minimal, hand-written stylesheet
   (no bundler): a dashboard of the installations and repositories the user
   owns or is granted, with each one's latest review status; a repository's
   review history; a run's findings; and owner pages for repository
   settings, access grants, providers (OpenRouter key, Codex login), and
   review defaults. AshAdmin stays the admin tool. **Implemented**: LiveViews
   `ReposLive`, `RepositoryLive`, `ReviewLive`, `InstallationLive`,
   `SettingsLive`, and `GrantsComponent` in one `live_session` behind
   `Auth.require_user`; pull request titles on review requests; lists
   filtered with `Forges.AccessCheck.visible/2` so admins see only their own
   there too. Later usability work: owners request reviews, review again, and
   retry posting on these pages (`Triggers.owner_command/4`, the same path as
   a `/tackle review` comment); a getting-started checklist on `/repos`;
   providers show whether they have credentials and are enabled by their
   first ones. **Live pages** (replacing a ten-second refresh timer):
   `Tackle.Web.Updates`, an Ash notifier on the resources the pages show,
   sends payload-free PubSub messages once writes commit (the review job's
   `Store` transactions run in `Ash.transact/3` for that), and each page
   reads again with its user as the actor; review jobs report their phase and
   `Tackle.Review` events to `Tackle.Web.ReviewProgress` (a `Registry` per
   request, owned by the job's process), which the review, repository, and
   repositories pages show as the CLI's review view does.
9. **Feedback** (§7.13). **Implemented.** Resolved threads (by writers) and the owner's
   choice → `Dismissal`s → known fingerprints; reactions → counts on
   findings.

## 9. Environment notes for the next agent

- Use `nix develop`. In some shells `tackle_lib`'s rebar3 dependencies
  (`idna` and others) fail to build with the `rebar3` that Mix downloads into
  `.nix-mix`; set `MIX_REBAR3=$(which rebar3)` to use the dev shell's.
- `gix_ex` builds a Rust NIF (`cargo`); the first compile takes a while.
- After changing dependencies of the CLI (and later the web app), regenerate
  the Nix dependency files (`mix deps.nix` in the app) and run
  `nix fmt -- <file>` on the result; check with
  `nix eval .#packages.<system>.<package>.drvPath`. New files must be
  `git add`ed before the flake sees them.
- The pre-commit hook runs credo for `packages/tackle`,
  `packages/tackle_review`, and `packages/tackle_tools` (`flake.nix`); add
  the app there.
- Untracked files in the working tree (`docs/code-review-plan.md`, review
  benchmark cases, logs) belong to the user; leave them alone.

## 10. Open points

- Which models to set as the review defaults; an operator setting, not code
  (§6, `ReviewDefaults`).

## 11. Deferred, not in the MVP

- **Gitea**: a `Forge.Gitea` module with a bot user and an encrypted access
  token, OAuth2 for sign-in, webhook HMAC, and Gitea's pull review API.
- Chat with a coding agent: would extend `Tackle.Web.AgentBackend` with
  persisted conversations.
- Multi-tenancy, billing, and sign-up.

# tackle_web plan: forge review bot

**Status: plan. Nothing here is implemented.** It builds on
[`REVIEW_PACKAGE_PLAN.md`](REVIEW_PACKAGE_PLAN.md) (phases 1 to 4, done).

## Goal

A web application, `apps/tackle_web`, that reviews pull requests of a
company's repositories with `packages/tackle_review` and posts the findings
as a review on the pull request. It runs on one NixOS server, for one
company. GitHub comes first; Gitea later; a chat with a coding agent, like
the harness's, later still. Nothing in it should block a hosted, multi-tenant
version, but tenancy, billing, and sign-up are not built.

The name reuses `apps/tackle_web`, removed in `c6c9e84`; nothing from that
app is reused.

## Decisions taken

- **PostgreSQL** with Ecto (`ecto_sql`, `postgrex`).
- **NixOS** hosting on a local server: a package and a NixOS module in this
  flake.
- **App name** `apps/tackle_web`, OTP application `:tackle_web`, namespace
  `Tackle.Web.*`, so a later chat feature fits the name.
- **Forge-neutral core**: GitHub and later Gitea are implementations of one
  `Tackle.Web.Forge` behaviour; nothing outside a forge module knows the
  forge's API.

## Shape

```
tackle_lib ◄── tackle_runtime ◄── tackle_review
    ▲                ▲                 ▲
tackle_tools         │                 │
    ▲                │                 │
    └──────────── tackle_web ──────────┘   Phoenix, Ecto/Postgres, forges
```

`tackle_web` does **not** depend on the harness (`packages/tackle`). The
harness is built for a local agent: `config.json` and `TACKLE_HOME`, file
sessions and journals, a file credential store, agent and skill discovery,
`AGENTS.md`, and `Tackle.Session` as its agent process. None of that maps to
a server with Postgres.

What the app uses instead:

- `tackle_runtime` for scopes, admission, limits, delegation, and
  cancellation. Its supervision tree leaves one slot to the host: the agent
  process, provided by an `AgentBackend`. **The app implements its own
  backend** (`Tackle.Web.AgentBackend`): one process per agent that runs
  `Tackle.Lib` turns, emits events, and keeps what it must in Postgres, and
  that implements the review's spec callbacks (`configure/2`, `describe/1`,
  `llm/1`). This is where a local and a web host differ; the harness's
  equivalent is `Tackle.Session`. A later chat extends the same backend with
  persisted conversations.
- `tackle_tools` (extracted from the harness, done) for `read` and `bash`
  and the jailed executor.
- `tackle_lib` for providers (`Tackle.Lib.LLM.Provider`) and credentials:
  the app implements `Tackle.Lib.CredentialStore` on Postgres.
- `tackle_review` for reviews, with stage specs built from
  `Tackle.Review.Stages`, rules read from the base commit, settings and known
  findings from the database, and the result recorded by the app.

## Components

### Forge contract

`Tackle.Web.Forge` (behaviour), first implemented by `Tackle.Web.Forge.GitHub`:

- verify and decode a webhook (signature check, event type, delivery id);
- the pull request: number, title, author, base and head refs and SHAs,
  whether the head is a fork;
- whether a user may trigger a review (write access to the repository);
- fetch credentials for one repository (a short-lived token) and its clone URL;
- post a review: one summary and line comments on the diff;
- read feedback on posted comments (resolved threads, replies, reactions).

GitHub access is a **GitHub App** installed on the company organisation:
an app JWT signed with its private key (RS256 through OTP's `:public_key`,
no JWT dependency), short-lived installation tokens, and webhooks with an
HMAC secret (`:crypto`). Tokens stay in the host process and are never
written to disk or given to a jail.

### Data (Ecto)

- `forge_installations` - forge, external id, account; tokens are not stored.
- `repositories` - installation, owner/name, enabled, trigger mode
  (`command` or `auto`), review profile, settings (the JSON form of
  `Tackle.Review.Settings`).
- `review_requests` - repository, pull request, head SHA, base SHA, trigger,
  requester, status; unique on (repository, pull request, head SHA) so
  redelivered webhooks and repeated commands do not review twice.
- `review_runs` - request, the `Result` summary (counts, stages, usage,
  rule and prompt digests, settings), timing, error.
- `findings` - run, fingerprint, the finding, shown/rejected, the forge
  comment id when posted.
- `finding_outcomes` - fingerprint, repository, outcome (`dismissed`,
  `fixed`, `useful`, `not_useful`), source (forge feedback or admin), time.
  The dismissed fingerprints of a repository are the next review's
  `:known_fingerprints`.

Every row hangs off an installation, so a later multi-tenant version adds
an account above it rather than rewriting the tables.

### Review job

A queue of `review_requests` with a small worker pool (concurrency 1 or 2
at first) and a daily token budget per repository:

1. **Fetch.** One bare clone per repository under the state directory;
   fetch the base branch and the pull request's head
   (`refs/pull/N/head` on GitHub) with the installation token passed per
   command, never stored in Git's configuration. Git runs with
   `GIT_CONFIG_NOSYSTEM`, an empty global configuration, and hooks disabled.
2. **Worktree.** A detached worktree of the head SHA for this run, removed
   afterwards. It is the jail's workspace.
3. **Rules and settings.** `Tackle.Review.Rules.read_tree/3` at the **base**
   SHA, loaded with `Rules.load/2`, so a pull request cannot change the rules
   it is reviewed against; settings from the repository row.
4. **Scope.** A scope on the app's backend whose root only requests runs,
   and the two stage specs from `Tackle.Review.Stages` with `read`, `bash`,
   and the output tools, on a jailed executor (`Tackle.Executor.Jailed`) for
   the worktree.
5. **Review.** `Tackle.Review.run/2` on the change `base...head`, with the
   repository's known fingerprints; progress events update the request's
   status for the UI.
6. **Record and post.** Store the run and findings, then post one review:
   findings on lines of the diff as line comments, the rest and the summary
   in the review body. A fingerprint already posted on this pull request is
   not posted again.

### Jail for untrusted code

Pull requests are untrusted input, including prompt injection aimed at the
agents. The review jail is a variant of `nix/packages/exec-jail.nix`:

- **no network** and **no Nix daemon or `/nix` mount** beyond the tool
  closure (the CLI's jail keeps both);
- the worktree mounted **read-only**; no credentials, no state directory,
  no environment from the service;
- review agents get only `read`, read-only `bash`, and the output tools.

This needs two new options in `exec-jail.nix` (network and read-only
workspace) and a `tackle-review-jail` package. `bubblewrap` needs
unprivileged user namespaces; the NixOS module must not forbid them in the
service's systemd hardening.

### Triggers and limits

- `/tackle review` in a pull request comment, from a user with write access.
- Automatic review of opened and updated pull requests, off by default per
  repository.
- Pull requests from forks are only reviewed on a command.
- A per-repository daily token budget, from `result.usage`.

### Web interface

Phoenix with LiveView, without a JavaScript build step at first (Phoenix
and LiveView ship their JavaScript in their packages; styling is plain CSS).

- `POST /webhooks/:forge` - webhook endpoint.
- Sign-in with the forge (GitHub OAuth through the same app), allowed for
  members of the installed organisation only.
- Pages: installations and repositories (enable, trigger mode, profile,
  settings), review runs (status, findings, cost), and a finding's outcome.

### Deployment

- `nix/packages/tackle-web.nix`: a Mix release of the app.
- `nixosModules.tackle-web`: `services.tackle-web` with a dedicated user, a
  state directory (clones and worktrees), an environment file for
  secrets (app id, private key path, webhook secret, OAuth client secret,
  `SECRET_KEY_BASE`), the database URL, the listen address, and the review
  jail. PostgreSQL through `services.postgresql`
  (`ensureDatabases`/`ensureUsers`), migrations on start.
- The server must be reachable by the forge's webhooks (for example through
  a reverse proxy or tunnel); this plan does not set that up.

## Phases

Each phase ends with the app compiling with `--warnings-as-errors`,
formatted, credo-clean, and tested; tests use fake forges and fake model
adapters and need no network or credentials, but do need a Postgres
(the dev shell gets one).

0. **Extraction.** *Done:* `packages/tackle_tools` holds the coding tools
   and executors, so the app needs nothing from the harness.
1. **Skeleton.** Phoenix app, Ecto repository and the first migrations,
   health endpoint, dev shell Postgres, CI job, Nix package and a NixOS
   module that starts it.
2. **Forge and webhooks.** `Tackle.Web.Forge`, GitHub App authentication,
   the webhook endpoint with signature checks, installations and
   repositories kept in sync, and the trigger rules.
3. **Review job.** The app's agent backend, provider configuration and the
   Postgres credential store, clones and worktrees, the review jail
   (`exec-jail.nix` options, `tackle-review-jail`), scope composition,
   `Tackle.Review.run/2`, and storing runs and findings.
4. **Posting.** Mapping findings to review comments and the summary, and
   not posting a finding twice.
5. **Interface.** Sign-in, repository settings, runs and findings.
6. **Feedback.** Forge feedback and admin actions become outcomes, and
   outcomes become known fingerprints.

## Dependencies to approve

Phoenix (`phoenix`, `phoenix_live_view`, `phoenix_html`, `bandit`),
Ecto (`ecto_sql`, `postgrex`), and `req` for forge HTTP (already used by
the provider adapters). JWT, HMAC, and JSON use OTP and Elixir's standard
library. Whether to add **Oban** for the job queue is an open question
below.

## Open questions

1. **Job queue:** Oban (Postgres-backed, retries, uniqueness, a known
   quantity) or a small queue of our own on the `review_requests` table?
2. **Model credentials on the server:** a provider with an API key in the
   environment file (Anthropic, OpenRouter), or a Codex login stored in the
   Postgres credential store (the login flow is in `tackle_codex`)?
3. **Sign-in:** forge OAuth as above, or leave authentication to a reverse
   proxy on the local network for now?
4. **`packages/tackle_phoenix`:** unused by this plan; its `Runner` and
   `Store` may serve the later chat, or the app's own backend may. Keep it
   until the chat is planned?

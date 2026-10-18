import Config

# `namespace` makes Phoenix's generators use Tackle.Hub and Tackle.HubWeb
# instead of the TackleHub and TackleHubWeb they derive from the app name.
config :tackle_hub,
  namespace: Tackle.Hub,
  ecto_repos: [Tackle.Hub.Repo],
  ash_domains: [
    Tackle.Hub.Forges,
    Tackle.Hub.Reviews,
    Tackle.Hub.Models,
    Tackle.Hub.Accounts
  ]

config :tackle_hub, Tackle.Hub.Repo, migration_timestamps: [type: :utc_datetime_usec]

# Development and tests connect to a PostgreSQL server on localhost:5432 as
# postgres/postgres; the standard PGHOST, PGPORT, PGUSER, and PGPASSWORD
# override that. TACKLE_HUB_PGHOST instead selects the Unix socket directory
# of a cluster from scripts/db.sh. Production is configured in runtime.exs.
if config_env() in [:dev, :test] do
  connection =
    case System.get_env("TACKLE_HUB_PGHOST") do
      nil ->
        [
          hostname: System.get_env("PGHOST", "localhost"),
          port: String.to_integer(System.get_env("PGPORT", "5432")),
          username: System.get_env("PGUSER", "postgres"),
          password: System.get_env("PGPASSWORD", "postgres")
        ]

      socket_dir ->
        [socket_dir: socket_dir, username: "postgres"]
    end

  config :tackle_hub, Tackle.Hub.Repo, connection
end

config :tackle_hub, Tackle.HubWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [json: Tackle.HubWeb.ErrorJSON, html: Tackle.HubWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: Tackle.Hub.PubSub,
  # Signs LiveView tokens with keys derived from SECRET_KEY_BASE; not secret.
  live_view: [signing_salt: "BzkNGThMDKFvl2FG"]

# Reviews run one or two at a time (docs/TACKLE_HUB_PLAN.md §7.5); `forge`
# runs the forge API calls that webhooks must not wait for, such as review
# commands' permission checks. Lifeline
# retries jobs orphaned by a crash or restart; the review job then decides
# from the request's status what is left to do. Lifeline cannot tell an
# orphaned job from a slow one, so `rescue_after` must stay longer than the
# review job's timeout.
config :tackle_hub, Oban,
  engine: Oban.Engines.Basic,
  repo: Tackle.Hub.Repo,
  queues: [reviews: 1, forge: 5],
  plugins: [
    {Oban.Plugins.Cron, crontab: []},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}
  ]

# Our code encodes and decodes JSON with the standard library's `JSON`.
config :phoenix, :json_library, JSON

# Request logs leave out the setup token, OAuth and registration codes, and
# their `state` (Tackle.HubWeb.SetupController, Tackle.HubWeb.AuthController).
config :phoenix, :filter_parameters, ["password", "token", "code", "state", "secret"]

import_config "ash.exs"

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :postgres,
        :resource,
        :admin,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [:admin, :resources, :policies, :authorization, :domain, :execution]
    ]
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"

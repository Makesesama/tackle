import Config

config :tackle_web,
  ecto_repos: [Tackle.Web.Repo],
  ash_domains: [
    Tackle.Web.Forges,
    Tackle.Web.Reviews,
    Tackle.Web.Models,
    Tackle.Web.Accounts
  ]

config :tackle_web, Tackle.Web.Repo, migration_timestamps: [type: :utc_datetime_usec]

config :tackle_web, Tackle.Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [formats: [json: Tackle.Web.ErrorJSON], layout: false],
  pubsub_server: Tackle.Web.PubSub

# Reviews run one or two at a time (docs/TACKLE_WEB_PLAN.md §7.5). Lifeline
# retries jobs orphaned by a crash or restart; the review job then decides
# from the request's status what is left to do. Lifeline cannot tell an
# orphaned job from a slow one, so `rescue_after` must stay longer than the
# review job's timeout.
config :tackle_web, Oban,
  engine: Oban.Engines.Basic,
  repo: Tackle.Web.Repo,
  queues: [reviews: 1],
  plugins: [
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}
  ]

# Our code encodes and decodes JSON with the standard library's `JSON`.
config :phoenix, :json_library, JSON

config :ash,
  default_string_length_count: :codepoints,
  include_embedded_source_by_default?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :postgres,
        :resource,
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
    "Ash.Domain": [section_order: [:resources, :policies, :authorization, :domain, :execution]]
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"

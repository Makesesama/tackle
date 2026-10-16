[
  import_deps: [
    :ash,
    :ash_postgres,
    :ash_oban,
    :ash_cloak,
    :ash_phoenix,
    :ash_admin,
    :ecto,
    :ecto_sql,
    :phoenix,
    :phoenix_live_view,
    :plug
  ],
  subdirectories: ["priv/*/migrations"],
  plugins: [Spark.Formatter],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}", "priv/*/seeds.exs"]
]

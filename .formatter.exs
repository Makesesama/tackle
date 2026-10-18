# Repository-level formatting for the independent apps and packages.
# apps/tackle_hub is formatted with its own .formatter.exs (Ash and Phoenix
# DSLs); run `mix format` there. See nix/treefmt.nix.
[
  inputs: [
    ".formatter.exs",
    "packages/*/{mix,.formatter}.exs",
    "packages/*/{config,lib,test}/**/*.{ex,exs}",
    "apps/tackle_cli/{mix,.formatter}.exs",
    "apps/tackle_cli/{config,lib,test}/**/*.{ex,exs}"
  ]
]

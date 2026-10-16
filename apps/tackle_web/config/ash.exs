import Config

# Ash's settings, several of them read at compile time by every dependency
# that defines Ash resources. Kept in their own file so the Nix package
# compiles those dependencies with exactly these values
# (nix/packages/tackle-web.nix); a release refuses to boot when compile-time
# and runtime configuration differ. Only `:ash` belongs here.
config :ash,
  default_string_length_count: :codepoints,
  include_embedded_source_by_default?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false]

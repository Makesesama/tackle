import Config

# The local ExRatatui fork contains the width-aware Markdown measurement NIF.
# Its 0.13.1 version still points RustlerPrecompiled at the published binary,
# so force a source build while this dependency remains a local path.
config :rustler_precompiled, :force_build, ex_ratatui: true

config :tackle_cli,
  default_adapters: [Tackle.Plugins.Codex, Tackle.Plugins.DeepSeek]

import_config "#{config_env()}.exs"

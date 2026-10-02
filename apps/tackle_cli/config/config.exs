import Config

config :tackle_cli,
  default_adapters: [Tackle.Plugins.Codex, Tackle.Plugins.DeepSeek, Tackle.Plugins.Anthropic]

import_config "#{config_env()}.exs"

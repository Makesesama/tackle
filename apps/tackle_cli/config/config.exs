import Config

config :tackle_cli,
  default_adapters: [
    Tackle.Plugins.Codex,
    Tackle.Plugins.DeepSeek,
    Tackle.Plugins.Anthropic,
    Tackle.Plugins.OpenRouter,
    Tackle.Plugins.Ollama,
    Tackle.Plugins.OllamaLocal
  ]

# Local Ollama models are never discovered from the server. The CLI makes the
# tev1 decision model selectable as `ollama/tev1:4b`; chat models stay
# host-configured.
config :tackle_ollama, Tackle.Plugins.OllamaLocal, decision_models: ["tev1:4b"]

import_config "#{config_env()}.exs"

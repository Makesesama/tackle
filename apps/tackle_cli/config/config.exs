import Config

config :tackle_cli,
  default_adapters: [
    Tackle.Plugins.Codex,
    Tackle.Plugins.DeepSeek,
    Tackle.Plugins.Anthropic,
    Tackle.Plugins.OpenRouter,
    Tackle.Plugins.Ollama
  ]

# Local Ollama models are never discovered from the server. The CLI makes the
# tev1 decision model selectable on the default local `ollama` provider as
# `ollama/tev1:4b` (for the command watchdog and workflow `tackle.classify`)
# and the small chat model `ollama/gemma4:12b` (for narration); other local
# models are declared in config.json's "providers" object.
config :tackle_ollama, Tackle.Plugins.Ollama,
  providers: %{
    "ollama" => %{"models" => ["gemma4:12b"], "decision_models" => ["tev1:4b"]}
  }

import_config "#{config_env()}.exs"

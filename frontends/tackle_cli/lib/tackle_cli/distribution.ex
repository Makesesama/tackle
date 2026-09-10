defmodule Tackle.CLI.Distribution do
  @moduledoc false

  @default_adapters [Tackle.Plugins.Codex, Tackle.Plugins.DeepSeek]

  @doc "Installs default CLI distribution contributions before the harness starts."
  @spec configure() :: :ok
  def configure do
    if is_nil(Application.get_env(:tackle, :adapters)) do
      Application.put_env(:tackle, :adapters, default_adapters())
    end

    :ok
  end

  @doc "Returns the adapters bundled with the default CLI distribution."
  @spec default_adapters() :: [module()]
  def default_adapters do
    Application.get_env(:tackle_cli, :default_adapters, @default_adapters)
  end
end

defmodule Tackle.PluginsTest do
  use ExUnit.Case, async: false

  defmodule Adapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "plugged"

    @impl true
    def models, do: ["small", "large"]

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}
  end

  defmodule Instances do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "inst"

    @impl true
    def default_providers,
      do: [{"inst", %{"models" => ["local"], "local" => true}}, {"inst-cloud", %{}}]

    @impl true
    def models(settings), do: Map.get(settings, "models", ["cloud"])

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}
  end

  # Like a local server's adapter: its models come only from config.json.
  defmodule ConfigOnly do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "cfg"

    @impl true
    def models(settings), do: Map.get(settings, "models", [])

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}
  end

  alias Tackle.Plugins

  setup do
    previous = Application.get_env(:tackle, :adapters)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:tackle, :adapters)
        value -> Application.put_env(:tackle, :adapters, value)
      end
    end)

    :ok
  end

  test "loads available adapters from root harness configuration" do
    Application.put_env(:tackle, :adapters, [Adapter])

    assert {:ok, [Adapter]} = Tackle.Plugins.available_adapters()
    assert {:ok, ["plugged/small", "plugged/large"]} = Tackle.available_models()
  end

  test "configuration loading uses root adapters while overrides only select the model" do
    Application.put_env(:tackle, :adapters, [Adapter])

    assert {:ok, config} = Tackle.load_config(overrides: [model: "plugged/small"], env: %{})
    assert [%Tackle.Lib.LLM.Provider{id: "plugged", adapter: Adapter}] = config.providers
    assert config.model_ref == "plugged/small"
  end

  test "configuration loading defaults to the first configured model" do
    Application.put_env(:tackle, :adapters, [Adapter])
    home = Path.join(System.tmp_dir!(), "tackle-plugins-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(home) end)

    assert {:ok, config} = Tackle.load_config(env: %{"TACKLE_HOME" => home})
    assert config.model_ref == "plugged/small"
  end

  test "merges defaults, accounts, and config providers" do
    accounts = %{
      "inst-work" => %{"adapter" => "inst"},
      "inst" => %{"adapter" => "inst"},
      "cloud2" => %{"adapter" => "inst", "base" => "inst-cloud"}
    }

    declarations = %{
      "inst" => %{"adapter" => "inst", "models" => ["tuned"]},
      "inst-cloud" => %{"adapter" => "inst", "region" => "eu"},
      "inst-work" => %{"adapter" => "inst", "base_url" => "http://work"},
      "cloud2" => %{"adapter" => "inst", "region" => "us"},
      "gpu" => %{"adapter" => "inst", "models" => ["big"]}
    }

    assert {:ok, entries} = Plugins.merge_providers([Adapter, Instances], accounts, declarations)

    assert Enum.map(entries, &{&1.provider.id, &1.provider.adapter, &1.source}) == [
             {"plugged", Adapter, :default},
             {"inst", Instances, :default},
             {"inst-cloud", Instances, :default},
             {"cloud2", Instances, :account},
             {"inst-work", Instances, :account},
             {"gpu", Instances, :config}
           ]

    settings = Map.new(entries, &{&1.provider.id, &1.provider.settings})
    assert settings["inst"] == %{"models" => ["tuned"], "local" => true}
    assert settings["inst-cloud"] == %{"region" => "eu"}
    assert settings["inst-work"] == %{"base_url" => "http://work"}
    assert settings["gpu"] == %{"models" => ["big"]}
    # An account inherits its base provider's merged settings; its own
    # config.json entry merges over them.
    assert settings["cloud2"] == %{"region" => "us"}

    assert {:ok, refs} =
             Plugins.available_model_refs(
               adapters: [Adapter, Instances],
               accounts: accounts,
               config_providers: declarations
             )

    assert refs == [
             "plugged/small",
             "plugged/large",
             "inst/tuned",
             "inst-cloud/cloud",
             "cloud2/cloud",
             "inst-work/cloud",
             "gpu/big"
           ]
  end

  test "an account starts from its base provider's settings" do
    declarations = %{
      "inst" => %{"adapter" => "inst", "models" => ["tuned"], "api_key_env" => "INST_KEY"},
      "from-own" => %{"adapter" => "inst", "api_key_env" => "OWN_KEY"}
    }

    accounts = %{
      "from-inst" => %{"adapter" => "inst", "base" => "inst"},
      "from-own" => %{"adapter" => "inst", "base" => "inst"},
      "from-type" => %{"adapter" => "inst"},
      "from-gone" => %{"adapter" => "inst", "base" => "removed"},
      # A base of another adapter contributes nothing.
      "from-other" => %{"adapter" => "inst", "base" => "plugged"}
    }

    assert {:ok, entries} = Plugins.merge_providers([Adapter, Instances], accounts, declarations)
    settings = Map.new(entries, &{&1.provider.id, &1.provider.settings})

    # The base's environment key is not inherited.
    assert settings["inst"]["api_key_env"] == "INST_KEY"
    assert settings["from-inst"] == %{"models" => ["tuned"], "local" => true}

    # Its own config.json entry may name one.
    assert settings["from-own"] == %{
             "models" => ["tuned"],
             "local" => true,
             "api_key_env" => "OWN_KEY"
           }

    assert settings["from-type"] == %{}
    assert settings["from-gone"] == %{}
    assert settings["from-other"] == %{}
  end

  test "rejects invalid config and config conflicting with default providers" do
    assert {:error, {:provider_adapter_conflict, "plugged"}} =
             Plugins.merge_providers([Adapter, Instances], %{}, %{
               "plugged" => %{"adapter" => "inst"}
             })

    assert {:error, {:invalid_provider_declaration, "gpu"}} =
             Plugins.merge_providers([Adapter], %{}, %{"gpu" => %{"models" => []}})

    assert {:error, {:invalid_provider_id, "Bad"}} =
             Plugins.merge_providers([Adapter], %{}, %{"Bad" => %{"adapter" => "plugged"}})

    # Invalid ids fail even for adapters this host lacks.
    assert {:error, {:invalid_provider_id, "Bad"}} =
             Plugins.merge_providers([Adapter], %{}, %{"Bad" => %{"adapter" => "missing"}})

    assert {:error, {:invalid_account, "work"}} =
             Plugins.merge_providers([Adapter], %{"work" => "plugged"}, %{})
  end

  test "skips providers this host cannot use instead of failing" do
    merged = fn accounts, declarations ->
      assert {:ok, entries} =
               Plugins.merge_providers([Adapter, Instances], accounts, declarations)

      Enum.map(entries, &{&1.provider.id, &1.provider.adapter, &1.source})
    end

    defaults = [
      {"plugged", Adapter, :default},
      {"inst", Instances, :default},
      {"inst-cloud", Instances, :default}
    ]

    # config.json and auth.json are shared by every host on the machine, so
    # declarations and accounts of a missing adapter are skipped.
    assert merged.(%{"work" => %{"adapter" => "missing"}}, %{
             "gpu" => %{"adapter" => "missing"}
           }) == defaults

    # An account named like a provider of another adapter is skipped too.
    assert merged.(%{"inst-cloud" => %{"adapter" => "plugged"}}, %{}) == defaults

    assert merged.(%{"gpu" => %{"adapter" => "plugged"}}, %{
             "gpu" => %{"adapter" => "inst"}
           }) == Enum.concat(defaults, [{"gpu", Instances, :config}])
  end

  test "available providers default to stored accounts and config.json" do
    Application.put_env(:tackle, :adapters, [Adapter, Instances])
    home = Path.join(System.tmp_dir!(), "tackle-plugins-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(home) end)
    File.mkdir_p!(home)

    File.write!(
      Path.join(home, "config.json"),
      JSON.encode!(%{"providers" => %{"gpu" => %{"adapter" => "inst", "models" => ["big"]}}})
    )

    assert {:ok, providers} = Plugins.available_providers(env: %{"TACKLE_HOME" => home})
    assert Enum.map(providers, & &1.id) == ["plugged", "inst", "inst-cloud", "gpu"]

    assert {:ok, "plugged/small"} = Plugins.default_model_ref(providers)
    assert {:ok, "inst/local"} = Plugins.default_model_ref([Instances])
    assert {:error, :no_providers_configured} = Plugins.default_model_ref([])
  end

  test "models declared only in config.json are enough, whichever source names the adapters" do
    Application.put_env(:tackle, :adapters, [ConfigOnly])
    home = Path.join(System.tmp_dir!(), "tackle-plugins-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(home) end)
    env = %{"TACKLE_HOME" => home}

    # Without models, both paths fail the same way, after the merge.
    assert {:error, :no_models_configured} = Tackle.load_config(env: env, accounts: %{})

    assert {:error, :no_models_configured} =
             Tackle.load_config(available_adapters: [ConfigOnly], env: env, accounts: %{})

    File.mkdir_p!(home)

    File.write!(
      Path.join(home, "config.json"),
      JSON.encode!(%{"providers" => %{"cfg" => %{"adapter" => "cfg", "models" => ["local"]}}})
    )

    for opts <- [[], [available_adapters: [ConfigOnly]]] do
      assert {:ok, config} = Tackle.load_config(opts ++ [env: env, accounts: %{}])
      assert config.model_ref == "cfg/local"
    end

    assert {:ok, [ConfigOnly]} = Plugins.available_adapters()

    assert {:ok, ["cfg/local"]} = Plugins.available_model_refs(env: env, accounts: %{})
  end

  test "returns an explicit error when no adapters are configured" do
    Application.put_env(:tackle, :adapters, [])

    assert {:error, :no_adapters_configured} = Tackle.Plugins.available_adapters()

    assert {:error, :no_adapters_configured} =
             Tackle.load_config(overrides: [model: "none/test"], env: %{})
  end
end

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
  alias Tackle.Plugins.Catalog

  test "configuration loading uses the given adapters while overrides only select the model" do
    assert {:ok, config} =
             Tackle.Config.load(
               available_adapters: [Adapter],
               overrides: [model: "plugged/small"],
               env: %{}
             )

    assert [%Tackle.Lib.LLM.Provider{id: "plugged", adapter: Adapter}] = config.providers
    assert config.model_ref == "plugged/small"
  end

  test "configuration loading defaults to the first configured model" do
    home = Path.join(System.tmp_dir!(), "tackle-plugins-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(home) end)

    assert {:ok, config} =
             Tackle.Config.load(available_adapters: [Adapter], env: %{"TACKLE_HOME" => home})

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
             Plugins.available_model_refs([Adapter, Instances],
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

    assert {:error, {:invalid_provider, "gpu"}} =
             Plugins.merge_providers([Adapter], %{}, %{"gpu" => %{"models" => []}})

    assert {:error, {:invalid_provider, "Bad"}} =
             Plugins.merge_providers([Adapter], %{}, %{"Bad" => %{"adapter" => "plugged"}})

    # Invalid ids fail even for adapters this host lacks.
    assert {:error, {:invalid_provider, "Bad"}} =
             Plugins.merge_providers([Adapter], %{}, %{"Bad" => %{"adapter" => "missing"}})

    assert {:error, {:invalid_account, "work"}} =
             Plugins.merge_providers([Adapter], %{"work" => "plugged"}, %{})
  end

  # Declarations and accounts follow the rules config.json and auth.json
  # apply, whichever way they reach the merge.
  test "checks declarations and accounts as their files do" do
    assert {:error, {:invalid_provider, "gpu"}} =
             Plugins.merge_providers([Adapter], %{}, %{"gpu" => %{"adapter" => "Not An Id"}})

    assert Plugins.validate_declarations(%{"gpu" => %{"adapter" => "Not An Id"}}) ==
             {:error, {:invalid_provider, "gpu"}}

    assert {:error, {:invalid_account, "work"}} =
             Plugins.merge_providers([Adapter], %{"work" => %{"adapter" => "Not An Id"}}, %{})

    # auth.json accepts a null base, which is no base.
    assert {:ok, entries} =
             Plugins.merge_providers(
               [Adapter],
               %{"work" => %{"adapter" => "plugged", "base" => nil}},
               %{}
             )

    assert Enum.map(entries, &{&1.provider.id, &1.source}) == [
             {"plugged", :default},
             {"work", :account}
           ]
  end

  test "an account recorded with a null base is merged" do
    on_exit(fn -> Tackle.Auth.delete_account("plugged-nullbase") end)
    home = Path.join(System.tmp_dir!(), "tackle-plugins-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(home) end)

    assert :ok =
             Tackle.Auth.put_account("plugged-nullbase", %{"adapter" => "plugged", "base" => nil})

    assert {:ok, providers} =
             Plugins.available_providers([Adapter], env: %{"TACKLE_HOME" => home})

    assert "plugged-nullbase" in Enum.map(providers, & &1.id)

    assert {:ok, %{"plugged-nullbase" => account}} = Tackle.Auth.accounts()
    assert account == %{"adapter" => "plugged"}
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
    home = Path.join(System.tmp_dir!(), "tackle-plugins-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(home) end)
    File.mkdir_p!(home)

    File.write!(
      Path.join(home, "config.json"),
      JSON.encode!(%{"providers" => %{"gpu" => %{"adapter" => "inst", "models" => ["big"]}}})
    )

    assert {:ok, providers} =
             Plugins.available_providers([Adapter, Instances], env: %{"TACKLE_HOME" => home})

    assert Enum.map(providers, & &1.id) == ["plugged", "inst", "inst-cloud", "gpu"]

    assert {:ok, "plugged/small"} = Plugins.default_model_ref(providers)
    assert {:ok, "inst/local"} = Plugins.default_model_ref(tl(providers))
    assert {:error, :no_models_configured} = Plugins.default_model_ref([])
  end

  test "models declared only in config.json are enough" do
    home = Path.join(System.tmp_dir!(), "tackle-plugins-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(home) end)
    env = %{"TACKLE_HOME" => home}
    catalog = catalog([ConfigOnly])

    # Without models, both adapter sources fail the same way, after the merge.
    for source <- [[available_adapters: [ConfigOnly]], [catalog: catalog]] do
      assert {:error, :no_models_configured} =
               Tackle.Config.load(source ++ [env: env, accounts: %{}])
    end

    File.mkdir_p!(home)

    File.write!(
      Path.join(home, "config.json"),
      JSON.encode!(%{"providers" => %{"cfg" => %{"adapter" => "cfg", "models" => ["local"]}}})
    )

    for source <- [[available_adapters: [ConfigOnly]], [catalog: catalog]] do
      assert {:ok, config} = Tackle.Config.load(source ++ [env: env, accounts: %{}])
      assert config.model_ref == "cfg/local"
    end

    assert {:ok, ["cfg/local"]} =
             Plugins.available_model_refs([ConfigOnly], env: env, accounts: %{})
  end

  test "reports invalid options in the shapes Tackle.Config uses" do
    assert {:error, {:invalid_option, :accounts, :none}} =
             Plugins.provider_entries([Adapter], accounts: :none, config_providers: %{})

    assert {:error, {:invalid_option, :config_providers, []}} =
             Plugins.provider_entries([Adapter], accounts: %{}, config_providers: [])

    assert {:error, {:invalid_plugin_options, :none}} = Plugins.provider_entries([Adapter], :none)
  end

  test "adapters are explicit" do
    assert {:error, :no_adapters_configured} =
             Plugins.provider_entries([], accounts: %{}, config_providers: %{})

    assert {:error, {:invalid_adapters_configuration, Adapter}} =
             Plugins.provider_entries(Adapter, accounts: %{}, config_providers: %{})

    assert {:error, {:missing_option, :available_adapters}} =
             Tackle.Config.load(overrides: [model: "plugged/small"], env: %{})

    assert {:error, :no_adapters_configured} =
             Tackle.Config.load(catalog: catalog([]), overrides: [model: "none/test"], env: %{})
  end

  defp catalog(adapters) do
    {:ok, catalog} =
      Catalog.new(
        adapters: Enum.map(adapters, &%{module: &1, source: :test}),
        tools: [],
        hooks: []
      )

    catalog
  end
end

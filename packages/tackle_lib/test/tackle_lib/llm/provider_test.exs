defmodule Tackle.Lib.LLM.ProviderTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Decision
  alias Tackle.Lib.Decision.Request
  alias Tackle.Lib.Decision.Result
  alias Tackle.Lib.LLM
  alias Tackle.Lib.LLM.{Provider, Selection}

  defmodule InstanceAdapter do
    @moduledoc false
    @behaviour Tackle.Lib.LLM
    @behaviour Tackle.Lib.Decision

    @impl Tackle.Lib.LLM
    def adapter_id, do: "instance"

    @impl Tackle.Lib.LLM
    def default_providers,
      do: [
        {"instance", %{"models" => ["base"]}},
        {"instance-big", %{"models" => ["base", "big"]}}
      ]

    @impl Tackle.Lib.LLM
    def models(settings), do: Map.get(settings, "models", [])

    @impl Tackle.Lib.LLM
    def model_info(_model, settings) do
      case Map.fetch(settings, "context_window") do
        {:ok, window} -> %{context_window: window}
        :error -> nil
      end
    end

    @impl Tackle.Lib.LLM
    def generate(_schema, opts) do
      send(self(), {:generate_opts, opts})
      {:ok, %{data: %{"content" => "ok"}, usage: %{input_tokens: 1}, model: nil}}
    end

    @impl Tackle.Lib.Decision
    def decision_models(settings), do: Map.get(settings, "decision_models", [])

    @impl Tackle.Lib.Decision
    def local?(settings), do: Map.get(settings, "local", false)

    @impl Tackle.Lib.Decision
    def decide(%Request{} = request, opts) do
      send(self(), {:decide_opts, opts})
      {:ok, %Result{answers: %{}, model: request.model}}
    end
  end

  defmodule PlainAdapter do
    @moduledoc false
    def adapter_id, do: "plain"
    def models, do: ["m"]
    def generate(_schema, _opts), do: {:error, :unused}
  end

  defmodule BadDefaultsAdapter do
    @moduledoc false
    def adapter_id, do: "bad-defaults"
    def default_providers, do: [{"Not Valid", %{}}]
    def models, do: []
    def generate(_schema, _opts), do: {:error, :unused}
  end

  defmodule EmptyDefaultsAdapter do
    @moduledoc false
    def adapter_id, do: "empty-defaults"
    def default_providers, do: []
    def models, do: []
    def generate(_schema, _opts), do: {:error, :unused}
  end

  defp provider!(id, adapter, settings) do
    {:ok, provider} = Provider.new(id, adapter, settings)
    provider
  end

  describe "new/3" do
    test "validates the id, adapter, and settings" do
      assert {:ok, %Provider{id: "work", adapter: PlainAdapter, settings: %{}}} =
               Provider.new("work", PlainAdapter)

      assert Provider.new("Work", PlainAdapter) == {:error, {:invalid_provider_id, "Work"}}
      assert Provider.new("-a", PlainAdapter) == {:error, {:invalid_provider_id, "-a"}}

      assert Provider.new("work", "Elixir.X") ==
               {:error, {:invalid_adapter, "Elixir.X", :not_a_module}}

      assert Provider.new("work", PlainAdapter, [:x]) ==
               {:error, {:invalid_provider_settings, "work", [:x]}}
    end
  end

  describe "expand/1" do
    test "a bare module without default_providers/0 is one provider named by adapter_id/0" do
      assert {:ok, [%Provider{id: "plain", adapter: PlainAdapter, settings: %{}}]} =
               Provider.expand([PlainAdapter])
    end

    test "a bare module expands to its declared default providers in order" do
      assert {:ok, [%Provider{id: "instance"}, %Provider{id: "instance-big"}, %Provider{id: "x"}]} =
               Provider.expand([InstanceAdapter, provider!("x", PlainAdapter, %{})])
    end

    test "rejects duplicate provider ids across modules and structs" do
      assert Provider.expand([PlainAdapter, provider!("plain", InstanceAdapter, %{})]) ==
               {:error, {:duplicate_provider_id, "plain"}}
    end

    test "rejects invalid default providers" do
      assert Provider.expand([BadDefaultsAdapter]) ==
               {:error, {:invalid_provider_id, "Not Valid"}}

      assert Provider.expand([EmptyDefaultsAdapter]) ==
               {:error, {:invalid_default_providers, EmptyDefaultsAdapter, []}}
    end
  end

  describe "LLM.select/2 with providers" do
    test "two providers on one adapter keep separate models and settings" do
      work = provider!("work", InstanceAdapter, %{"models" => ["a"], "context_window" => 1000})
      home = provider!("home", InstanceAdapter, %{"models" => ["b"]})

      assert {:ok,
              %Selection{
                adapter: InstanceAdapter,
                provider_id: "work",
                provider_settings: %{"models" => ["a"]},
                model: "a",
                ref: "work/a",
                model_info: %{context_window: 1000}
              }} = LLM.select([work, home], "work/a")

      assert {:ok, %Selection{provider_id: "home", model_info: nil}} =
               LLM.select([work, home], "home/b")

      assert LLM.select([work, home], "home/a") == {:error, {:unknown_model, "home/a"}}

      assert LLM.select([work, home], "instance/base") ==
               {:error, {:unknown_provider, "instance"}}
    end

    test "default providers resolve by their own ids" do
      assert {:ok, %Selection{provider_id: "instance-big", model: "big"}} =
               LLM.select([InstanceAdapter], "instance-big/big")

      assert LLM.select([InstanceAdapter], "instance/big") ==
               {:error, {:unknown_model, "instance/big"}}
    end

    test "generation receives the provider id and settings and reports the provider id" do
      work = provider!("work", InstanceAdapter, %{"models" => ["a"]})
      {:ok, selection} = LLM.select([work], "work/a")

      assert {:ok, %{usage: usage}} =
               LLM.generate_with(selection, nil, provider_id: "spoofed", model: "x")

      assert_received {:generate_opts, opts}
      assert opts[:model] == "a"
      assert opts[:provider_id] == "work"
      assert opts[:provider_settings] == %{"models" => ["a"]}
      assert usage.provider == "work"
      assert Selection.provider(selection) == work
    end
  end

  describe "Decision.select/2 with providers" do
    test "decision models and locality are per provider" do
      local =
        provider!("box", InstanceAdapter, %{"decision_models" => ["judge"], "local" => true})

      remote = provider!("cloud", InstanceAdapter, %{"decision_models" => ["judge"]})

      assert {:ok, %Decision.Selection{provider_id: "box", local: true}} =
               Decision.select([local, remote], "box/judge")

      assert {:ok, %Decision.Selection{provider_id: "cloud", local: false} = selection} =
               Decision.select([local, remote], "cloud/judge")

      assert Decision.select([local], "box/other") ==
               {:error, {:unknown_decision_model, "box/other"}}

      assert Decision.select([PlainAdapter], "plain/m") ==
               {:error, {:unsupported_decision_adapter, "plain"}}

      question = Decision.Question.choice("v", "Stuck?", %{"yes" => nil, "no" => nil})
      assert {:ok, %Result{}} = Decision.decide(selection, "state", [question], [])
      assert_received {:decide_opts, opts}
      assert opts[:provider_id] == "cloud"
      assert opts[:provider_settings] == %{"decision_models" => ["judge"]}
    end

    test "a non-boolean local flag is reported with the provider id" do
      odd = provider!("odd", InstanceAdapter, %{"decision_models" => ["j"], "local" => :maybe})

      assert Decision.select([odd], "odd/j") == {:error, {:invalid_local_flag, "odd", :maybe}}
    end
  end

  test "provider functions load the adapter and report missing modules" do
    missing = %Provider{id: "gone", adapter: Nope.Missing, settings: %{}}

    assert {:error, {:invalid_adapter, Nope.Missing, {:not_loaded, _}}} = Provider.models(missing)
    assert {:error, {:invalid_adapter, Nope.Missing, {:not_loaded, _}}} = Provider.local?(missing)
  end

  test "id/2 and settings/1 read adapter options with fallbacks" do
    assert Provider.id([provider_id: "work"], "default") == "work"
    assert Provider.id([provider_id: ""], "default") == "default"
    assert Provider.id([], "default") == "default"
    assert Provider.settings(provider_settings: %{"a" => 1}) == %{"a" => 1}
    assert Provider.settings([]) == %{}
  end

  describe "adapter helpers" do
    defmodule KeyStore do
      @behaviour Tackle.Lib.CredentialStore

      @impl true
      def fetch(credentials, namespace) do
        case Map.fetch(credentials, namespace) do
          {:ok, {:fail, result}} -> result
          {:ok, value} -> {:ok, value}
          :error -> :error
        end
      end

      @impl true
      def put(_credentials, _namespace, _value), do: :ok

      @impl true
      def delete(_credentials, _namespace), do: :ok
    end

    test "string_setting/3 reads non-empty strings and reports anything else" do
      opts = [provider_id: "work", provider_settings: %{"url" => "u", "empty" => "", "n" => 1}]

      assert Provider.string_setting(opts, "url", "default") == {:ok, "u"}
      assert Provider.string_setting(opts, "missing", "default") == {:ok, nil}

      assert Provider.string_setting(opts, "empty", "default") ==
               {:error, {:invalid_provider_setting, "work", "empty", ""}}

      assert Provider.string_setting([provider_settings: %{"n" => 1}], "n", "default") ==
               {:error, {:invalid_provider_setting, "default", "n", 1}}
    end

    test "put_base_url/2 puts the setting unless :base_url is explicit" do
      settings = [provider_settings: %{"base_url" => "https://setting"}]

      assert {:ok, opts} = Provider.put_base_url(settings, "p")
      assert opts[:base_url] == "https://setting"

      assert {:ok, opts} = Provider.put_base_url([base_url: "https://explicit"] ++ settings, "p")
      assert Keyword.get_values(opts, :base_url) == ["https://explicit"]

      assert Provider.put_base_url([], "p") == {:ok, []}

      assert Provider.put_base_url([provider_settings: %{"base_url" => 1}], "p") ==
               {:error, {:invalid_provider_setting, "p", "base_url", 1}}
    end

    test "api_key/3 takes the explicit key, then the stored one, then the environment" do
      env = "TACKLE_PROVIDER_TEST_KEY_#{System.unique_integer([:positive])}"
      System.put_env(env, " env-key \n")
      on_exit(fn -> System.delete_env(env) end)

      store = {KeyStore, %{"p" => %{"api_key" => "stored"}, "other" => %{key: "atom"}}}

      assert Provider.api_key([api_key: " explicit ", credential_store: store], "p", env) ==
               {:ok, "explicit"}

      assert Provider.api_key([api_key: "  ", credential_store: store], "p", env) ==
               {:ok, "stored"}

      assert Provider.api_key([provider_id: "other", credential_store: store], "p", env) ==
               {:ok, "atom"}

      assert Provider.api_key([credential_store: {KeyStore, %{}}], "p", env) == {:ok, "env-key"}

      assert Provider.api_key([credential_store: {KeyStore, %{"p" => %{}}}], "p", env) ==
               {:ok, "env-key"}

      # Only the default provider falls back to the default variable; others
      # name theirs in "api_key_env".
      assert Provider.api_key([provider_id: "work"], "p", env) == :error

      assert Provider.api_key(
               [provider_id: "work", provider_settings: %{"api_key_env" => env}],
               "p"
             ) == {:ok, "env-key"}

      assert Provider.api_key([], "p") == :error
    end

    test "api_key/3 rejects unsafe keys and reports store and setting failures" do
      assert Provider.api_key([api_key: "bad key"], "p") == {:error, :invalid_api_key}
      assert Provider.api_key([api_key: "bad\nkey"], "p") == {:error, :invalid_api_key}

      failing = {KeyStore, %{"p" => {:fail, {:error, :unavailable}}}}

      assert Provider.api_key([credential_store: failing], "p") ==
               {:error, {:credential_store_failed, :unavailable}}

      assert Provider.api_key([credential_store: :not_a_handle], "p") ==
               {:error, :invalid_credential_store}

      assert Provider.api_key([provider_settings: %{"api_key_env" => ""}], "p") ==
               {:error, {:invalid_provider_setting, "p", "api_key_env", ""}}
    end
  end
end

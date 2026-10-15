defmodule Tackle.Runtime.SpecConfigurationTest do
  use ExUnit.Case, async: false

  alias Tackle.Runtime
  alias Tackle.Runtime.AgentContext
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.ScopeSpec

  # A backend whose configuration is a plain map. It runs agents as idle
  # processes; the tests only use the spec callbacks.
  defmodule Backend do
    @behaviour Tackle.Runtime.AgentBackend
    use GenServer

    @models ["test/fast", "test/slow"]

    @impl true
    def validate_spec(_spec), do: :ok

    @impl true
    def child_spec(spec, context), do: {__MODULE__, {spec, context}}

    def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

    @impl true
    def init({spec, context}) do
      :ok = AgentContext.register(context)
      {:ok, spec.config}
    end

    @impl true
    def call(pid, operation, args), do: GenServer.call(pid, {operation, args})

    @impl true
    def handle_call({:model, []}, _from, config), do: {:reply, config.model, config}

    @impl true
    def prepare_child(%AgentSpec{model_source: :parent} = spec, parent) do
      {:ok, put_in(spec.config.model, Runtime.AgentBackend.call(__MODULE__, parent, :model, []))}
    end

    def prepare_child(spec, _parent), do: {:ok, spec}

    @impl true
    def configure(%AgentSpec{config: %{mode: :raise}}, _opts), do: raise("configure failed")

    def configure(%AgentSpec{} = spec, opts) do
      Enum.reduce_while(opts, {:ok, spec}, fn option, {:ok, spec} ->
        case apply_option(spec.config, option) do
          {:ok, config} -> {:cont, {:ok, %{spec | config: config}}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end

    defp apply_option(config, {:model, model}) when model in @models,
      do: {:ok, %{config | model: model}}

    defp apply_option(_config, {:model, model}), do: {:error, {:unknown_model, model}}
    defp apply_option(config, {:thinking, level}), do: {:ok, %{config | thinking: level}}
    defp apply_option(config, {:max_steps, steps}), do: {:ok, %{config | max_steps: steps}}

    defp apply_option(config, {:context, context}),
      do: {:ok, %{config | context: Map.merge(config.context, context)}}

    defp apply_option(config, {:llm_opts, opts}),
      do: {:ok, %{config | llm_opts: Keyword.merge(config.llm_opts, opts)}}

    @impl true
    def describe(%AgentSpec{config: %{mode: :bad_description}}), do: :nope

    def describe(%AgentSpec{config: config}) do
      %{
        model: config.model,
        thinking: config.thinking,
        max_steps: config.max_steps,
        system_prompt: "Prompt.",
        tools: ["read"]
      }
    end

    @impl true
    def llm(%AgentSpec{config: config}),
      do:
        {:ok, %{llm: {:client, config.model}, llm_opts: [credential: :secret] ++ config.llm_opts}}
  end

  # Implements only the required callbacks.
  defmodule MinimalBackend do
    @behaviour Tackle.Runtime.AgentBackend
    use GenServer

    @impl true
    def validate_spec(_spec), do: :ok

    @impl true
    def child_spec(spec, context), do: {__MODULE__, {spec, context}}

    def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

    @impl true
    def init({_spec, context}) do
      :ok = AgentContext.register(context)
      {:ok, nil}
    end

    @impl true
    def call(_pid, operation, _args), do: {:error, {:unsupported_agent_operation, operation}}
  end

  defp config(overrides \\ %{}) do
    Map.merge(
      %{model: "test/fast", thinking: nil, max_steps: nil, context: %{}, llm_opts: [], mode: nil},
      overrides
    )
  end

  defp start(backend, root_config) do
    root = AgentSpec.new!(name: "root", config: root_config)
    {:ok, scope} = Runtime.start_scope(ScopeSpec.new!(backend: backend, root_spec: root))
    on_exit(fn -> Runtime.stop_scope(scope.scope_ref) end)
    scope.root_agent_ref
  end

  test "prepare_spec resolves an inheriting spec against the requester" do
    requester = start(Backend, config(%{model: "test/slow"}))
    inheriting = AgentSpec.new!(name: "child", config: config(), model_source: :parent)
    configured = AgentSpec.new!(name: "child", config: config())

    assert {:ok, %AgentSpec{config: %{model: "test/slow"}, model_source: :parent}} =
             Runtime.prepare_spec(requester, inheriting)

    assert {:ok, ^configured} = Runtime.prepare_spec(requester, configured)
  end

  test "configure_spec applies options in order through the scope's backend" do
    requester = start(Backend, config())
    spec = AgentSpec.new!(name: "child", config: config(%{llm_opts: [a: 1]}))

    assert {:ok, %AgentSpec{config: configured}} =
             Runtime.configure_spec(requester, spec,
               model: "test/slow",
               thinking: "low",
               max_steps: 3,
               context: %{review: :data},
               llm_opts: [prompt_cache_key: "key"]
             )

    assert %{model: "test/slow", thinking: "low", max_steps: 3} = configured
    assert configured.context == %{review: :data}
    assert configured.llm_opts == [a: 1, prompt_cache_key: "key"]

    assert {:ok, ^spec} = Runtime.configure_spec(requester, spec, [])

    assert {:error, {:unknown_model, "other/x"}} =
             Runtime.configure_spec(requester, spec, model: "other/x")

    assert {:error, {:invalid_configure_options, [:temperature]}} =
             Runtime.configure_spec(requester, spec, temperature: 1)

    assert {:error, {:invalid_configure_options, :bad}} =
             Runtime.configure_spec(requester, spec, :bad)

    failing = AgentSpec.new!(name: "child", config: config(%{mode: :raise}))

    assert {:error, {:agent_backend_failed, "configure failed"}} =
             Runtime.configure_spec(requester, failing, model: "test/slow")
  end

  test "describe_spec and spec_llm report what a spec runs with" do
    requester = start(Backend, config())
    spec = AgentSpec.new!(name: "child", config: config(%{thinking: "high", max_steps: 4}))

    assert {:ok,
            %{
              model: "test/fast",
              thinking: "high",
              max_steps: 4,
              system_prompt: "Prompt.",
              tools: ["read"]
            }} = Runtime.describe_spec(requester, spec)

    assert {:ok, %{llm: {:client, "test/fast"}, llm_opts: [credential: :secret]}} =
             Runtime.spec_llm(requester, spec)

    bad = AgentSpec.new!(name: "child", config: config(%{mode: :bad_description}))
    assert {:error, {:invalid_backend_description, :nope}} = Runtime.describe_spec(requester, bad)
  end

  test "a backend without the callbacks refuses them" do
    requester = start(MinimalBackend, %{})
    spec = AgentSpec.new!(name: "child", config: %{})

    assert {:error, {:unsupported_backend_callback, :configure}} =
             Runtime.configure_spec(requester, spec, max_steps: 2)

    assert {:error, {:unsupported_backend_callback, :describe}} =
             Runtime.describe_spec(requester, spec)

    assert {:error, {:unsupported_backend_callback, :llm}} = Runtime.spec_llm(requester, spec)
    # Without prepare_child/2, a spec is used as it is.
    assert {:ok, ^spec} = Runtime.prepare_spec(requester, spec)
  end
end

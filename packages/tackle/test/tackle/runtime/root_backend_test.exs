defmodule Tackle.Runtime.RootBackendTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Runtime
  alias Tackle.Runtime.{AgentSpec, RootBackend}

  # The spec callbacks code review uses to run its stages without reading
  # `Tackle.Config` itself (see `Tackle.Runtime.AgentBackend`).

  test "configure applies a model, thinking level, step limit, context, and adapter options" do
    spec = agent_spec("worker", context: %{own: true}, llm_opts: [reasoning_effort: "low"])

    assert {:ok, %AgentSpec{config: config}} =
             RootBackend.configure(spec,
               model: "test/child",
               thinking: "high",
               max_steps: 3,
               context: %{review: %{stage: :detector}},
               llm_opts: [prompt_cache_key: "key"]
             )

    assert config.model_ref == "test/child"
    assert config.llm.ref == "test/child"
    assert config.llm_opts[:reasoning_effort] == "high"
    assert config.llm_opts[:prompt_cache_key] == "key"
    assert config.max_iterations == 3
    assert config.context == %{own: true, review: %{stage: :detector}}
  end

  test "configure only selects models the configuration's providers offer" do
    spec = agent_spec("worker")

    assert {:error, _reason} = RootBackend.configure(spec, model: "other/model")
    assert {:error, _reason} = RootBackend.configure(spec, thinking: "huge")

    assert {:error, {:invalid_option, :max_steps, 0}} =
             RootBackend.configure(spec, max_steps: 0)

    assert {:error, {:invalid_option, :context, nil}} = RootBackend.configure(spec, context: nil)
  end

  test "describe reports what a spec runs with" do
    spec =
      agent_spec("worker",
        tools: [Tackle.Tools.Read],
        max_iterations: 4,
        llm_opts: [reasoning_effort: "medium"]
      )

    assert RootBackend.describe(spec) == %{
             model: "test/echo",
             thinking: "medium",
             max_steps: 4,
             system_prompt: "You are a test agent.",
             tools: ["read"]
           }

    unlimited = put_in(spec.config.max_iterations, :infinity)
    assert %{max_steps: nil} = RootBackend.describe(unlimited)
  end

  test "llm returns the model client with the session's credential store" do
    spec = agent_spec("worker")

    assert {:ok, %{llm: llm, llm_opts: llm_opts}} = RootBackend.llm(spec)
    assert llm.ref == "test/echo"
    assert Keyword.has_key?(llm_opts, :credential_store)
    assert llm_opts[:test_pid] == self()
  end

  test "the runtime reaches the callbacks through the requester's scope" do
    scope = start_scope(root: [allow_delegation: true])
    spec = agent_spec("worker")

    assert {:ok, %AgentSpec{config: %{max_iterations: 2}}} =
             Runtime.configure_spec(scope.root_agent_ref, spec, max_steps: 2)

    assert {:ok, %{model: "test/echo"}} = Runtime.describe_spec(scope.root_agent_ref, spec)
    assert {:ok, %{llm: _llm}} = Runtime.spec_llm(scope.root_agent_ref, spec)

    # An inheriting spec gets the requester's current model.
    assert {:ok, _snapshot} = Tackle.reconfigure(scope.root_agent_ref, model: "test/child")
    inheriting = %{spec | model_source: :parent}

    assert {:ok, %AgentSpec{config: %{model_ref: "test/child"}}} =
             Runtime.prepare_spec(scope.root_agent_ref, inheriting)
  end
end

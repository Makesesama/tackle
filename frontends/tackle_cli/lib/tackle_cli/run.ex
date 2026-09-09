defmodule Tackle.CLI.Run do
  @moduledoc false

  alias Tackle.Plugins.Codex.OAuth
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.ScopeSpec

  @codex_provider "openai-codex"
  @terminal_timeout 60_000

  @spec run(%{
          model: String.t() | nil,
          thinking: String.t() | nil,
          prompt: String.t() | nil
        }) :: non_neg_integer()
  def run(%{model: model, thinking: thinking, prompt: nil}) do
    case start_scope(model, thinking, true) do
      {:ok, scope} ->
        try do
          case Tackle.available_models() do
            {:ok, models} ->
              case Tackle.CLI.TUI.start(agent_ref: scope.root_agent_ref, models: models) do
                :ok -> 0
                {:error, reason} -> error(reason)
              end

            {:error, reason} ->
              error(reason)
          end
        after
          stop_scope(scope.scope_ref)
        end

      {:error, reason} ->
        error(reason)
    end
  end

  def run(%{model: model, thinking: thinking, prompt: prompt}) when is_binary(prompt) do
    case start_scope(model, thinking, false) do
      {:ok, scope} ->
        try do
          run_prompt(scope.root_agent_ref, prompt)
        after
          stop_scope(scope.scope_ref)
        end

      {:error, reason} ->
        error(reason)
    end
  end

  @spec models() :: non_neg_integer()
  def models do
    with {:ok, _apps} <- ensure_started(),
         {:ok, models} <- Tackle.available_models() do
      Enum.each(models, &IO.puts/1)
      0
    else
      {:error, reason} -> error(reason)
      reason -> error(reason)
    end
  end

  @spec auth_login(%{provider: String.t()}) :: non_neg_integer()
  def auth_login(%{provider: provider}) do
    with {:ok, _apps} <- ensure_started(),
         :ok <- supported_auth_provider(provider),
         {:ok, device} <- OAuth.request_device_code(),
         :ok <- print_device_instructions(device),
         {:ok, credentials} <- OAuth.complete_device_code(device),
         :ok <- Tackle.Auth.put(provider, credentials) do
      IO.puts("Stored credentials for #{provider}.")
      0
    else
      {:error, reason} -> error(reason)
      reason -> error(reason)
    end
  end

  @spec auth_status(%{provider: String.t() | nil}) :: non_neg_integer()
  def auth_status(%{provider: provider}) do
    provider = provider || @codex_provider

    with {:ok, _apps} <- ensure_started(),
         :ok <- supported_auth_provider(provider) do
      case Tackle.Auth.status(provider) do
        :stored ->
          IO.puts("#{provider}: stored")
          0

        :missing ->
          IO.puts("#{provider}: missing")
          1

        {:error, reason} ->
          error(reason)
      end
    else
      {:error, reason} -> error(reason)
      reason -> error(reason)
    end
  end

  @spec auth_logout(%{provider: String.t()}) :: non_neg_integer()
  def auth_logout(%{provider: provider}) do
    with {:ok, _apps} <- ensure_started(),
         :ok <- supported_auth_provider(provider),
         :ok <- Tackle.Auth.delete(provider) do
      IO.puts("Deleted credentials for #{provider}.")
      0
    else
      {:error, reason} -> error(reason)
      reason -> error(reason)
    end
  end

  defp start_scope(model, thinking, llm_stream) do
    with {:ok, _apps} <- ensure_started(),
         {:ok, overrides} <- overrides(model, thinking, llm_stream),
         {:ok, config} <- Tackle.load_config(overrides: overrides),
         {:ok, root_spec} <- AgentSpec.new(name: "root", config: config),
         {:ok, scope_spec} <- ScopeSpec.new(root_spec: root_spec, profiles: %{}),
         {:ok, scope} <- Tackle.start_scope(scope_spec) do
      {:ok, scope}
    else
      {:error, reason} -> {:error, reason}
      reason -> {:error, reason}
    end
  end

  defp run_prompt(agent_ref, prompt) do
    with {:ok, snapshot} <- Tackle.subscribe(agent_ref),
         {:ok, turn_id} <- Tackle.submit(agent_ref, prompt),
         {:ok, answer} <- await_answer(snapshot.session_id, turn_id) do
      IO.puts(answer)
      0
    else
      {:error, reason} -> error(reason)
    end
  end

  defp await_answer(session_id, turn_id) do
    receive do
      {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, agent_state}} ->
        {:ok, Tackle.Lib.last_answer(agent_state) || ""}

      {:tackle_turn_finished, ^session_id, ^turn_id, {:cancelled, _agent_state}} ->
        {:error, :cancelled}

      {:tackle_turn_finished, ^session_id, ^turn_id, {:error, agent_state}} ->
        {:error, agent_state.error || :turn_failed}

      {:tackle_turn_failed, ^session_id, ^turn_id, reason} ->
        {:error, reason}

      {:tackle_event, ^session_id, ^turn_id, _event} ->
        await_answer(session_id, turn_id)
    after
      @terminal_timeout -> {:error, :timeout}
    end
  end

  defp ensure_started do
    Tackle.CLI.Distribution.configure()
    Application.ensure_all_started(:tackle_cli)
  end

  defp supported_auth_provider(@codex_provider), do: :ok

  defp supported_auth_provider(provider),
    do: {:error, {:unsupported_auth_provider, provider, supported: [@codex_provider]}}

  defp print_device_instructions(device) do
    IO.puts("Open #{device.verification_uri} and enter code #{device.user_code}.")
    IO.puts("Waiting for authorization...")
    :ok
  end

  defp overrides(model, thinking, llm_stream) do
    overrides = if model, do: [model: model], else: []
    overrides = if llm_stream, do: Keyword.put(overrides, :llm_stream, true), else: overrides

    case thinking do
      nil -> {:ok, overrides}
      level -> {:ok, Keyword.put(overrides, :thinking, level)}
    end
  end

  defp stop_scope(scope_ref) do
    Tackle.stop_scope(scope_ref)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp error(reason) do
    IO.puts(:stderr, "error: #{inspect(reason)}")
    1
  end
end

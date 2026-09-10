defmodule Tackle.CLI.Run do
  @moduledoc false

  alias Tackle.CLI.Distribution
  alias Tackle.CLI.SecretInput
  alias Tackle.CLI.TUI
  alias Tackle.Plugins.Codex.OAuth
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.ScopeSpec
  alias Tackle.Session.Spec, as: SessionSpec

  @codex_provider "openai-codex"
  @deepseek_provider "deepseek"
  @auth_providers [@codex_provider, @deepseek_provider]
  @terminal_timeout 60_000

  @spec run(%{
          model: String.t() | nil,
          thinking: String.t() | nil,
          prompt: String.t() | nil,
          resume: String.t() | nil,
          abandon: boolean()
        }) :: non_neg_integer()
  def run(%{model: model, thinking: thinking, prompt: nil} = opts) do
    scope_opts = [resume: opts.resume, override_config: not is_nil(model)]

    case start_scope(model, thinking, true, scope_opts) do
      {:ok, scope} -> run_tui(scope, opts)
      {:error, reason} -> error(reason)
    end
  end

  def run(%{model: model, thinking: thinking, prompt: prompt} = opts) when is_binary(prompt) do
    scope_opts = [resume: opts.resume, override_config: not is_nil(model)]

    case start_scope(model, thinking, false, scope_opts) do
      {:ok, scope} -> run_prompt_scope(scope, prompt, opts)
      {:error, reason} -> error(reason)
    end
  end

  defp run_tui(scope, opts) do
    case ensure_recoverable(scope.root_agent_ref, opts.abandon) do
      :ok -> start_tui(scope, opts)
      {:error, reason} -> error(reason)
    end
  after
    stop_scope(scope.scope_ref)
  end

  defp start_tui(scope, opts) do
    case Tackle.available_models() do
      {:ok, models} -> start_tui_session(scope, models, opts)
      {:error, reason} -> error(reason)
    end
  end

  defp start_tui_session(scope, models, opts) do
    case TUI.start(
           agent_ref: scope.root_agent_ref,
           models: models,
           new_session: new_session_fun(opts)
         ) do
      :ok -> 0
      {:error, reason} -> error(reason)
    end
  end

  # A new session is a fresh root scope: a new durable session id and a new
  # root agent, started and stopped by the frontend while the shell stays up.
  # The live model and reasoning level carry over unless the frontend cannot
  # report them, in which case the command-line selection is used again.
  defp new_session_fun(opts) do
    fn overrides ->
      start_scope(
        Map.get(overrides, :model) || opts.model,
        Map.get(overrides, :thinking) || opts.thinking,
        true,
        resume: nil,
        override_config: false
      )
    end
  end

  defp run_prompt_scope(scope, prompt, opts) do
    case ensure_recoverable(scope.root_agent_ref, opts.abandon) do
      :ok -> run_prompt(scope.root_agent_ref, prompt)
      {:error, reason} -> error(reason)
    end
  after
    stop_scope(scope.scope_ref)
  end

  @spec sessions(%{query: String.t() | nil, limit: pos_integer() | nil}) :: non_neg_integer()
  def sessions(%{query: query, limit: limit}) do
    with {:ok, _apps} <- ensure_started(),
         {:ok, filters} <- session_filters(limit),
         {:ok, %{sessions: sessions}} <- list_sessions(query, filters) do
      Enum.each(sessions, &puts_session/1)
      0
    else
      {:error, reason} -> error(reason)
      reason -> error(reason)
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
         :ok <- login(provider) do
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

  defp start_scope(model, thinking, llm_stream, opts) do
    with {:ok, _apps} <- ensure_started(),
         {:ok, overrides} <- overrides(model, thinking, llm_stream),
         {:ok, config} <- Tackle.load_config(overrides: overrides),
         {:ok, root_spec} <- AgentSpec.new(name: "root", config: config),
         {:ok, session} <- durable_session(opts),
         {:ok, scope_spec} <- ScopeSpec.new(root_spec: root_spec, profiles: %{}, session: session),
         {:ok, scope} <- Tackle.start_scope(scope_spec) do
      {:ok, scope}
    else
      {:error, reason} -> {:error, reason}
      reason -> {:error, reason}
    end
  end

  # Root conversations are durable by default. An explicit resume selects an
  # existing session; `override_config` is set only when the user chose a model
  # on the command line, so an unmodified resume adopts the recorded selection.
  defp durable_session(opts) do
    SessionSpec.new(
      session_id: Keyword.get(opts, :resume),
      override_config: Keyword.get(opts, :override_config, false)
    )
  end

  defp ensure_recoverable(agent_ref, abandon?) do
    case Tackle.snapshot(agent_ref) do
      {:ok, %{recovery: nil}} ->
        :ok

      {:ok, %{recovery: recovery}} ->
        if abandon? do
          Tackle.abandon_turn(agent_ref)
        else
          {:error, {:interrupted_session, recovery}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp session_filters(nil), do: {:ok, %{}}
  defp session_filters(limit) when is_integer(limit) and limit > 0, do: {:ok, %{limit: limit}}
  defp session_filters(limit), do: {:error, {:invalid_limit, limit}}

  defp list_sessions(nil, filters), do: Tackle.list_sessions(filters)
  defp list_sessions(query, filters), do: Tackle.search_sessions(query, filters)

  defp puts_session(session) do
    title = session.title || session.preview || "(untitled)"

    IO.puts(
      "#{session.session_id}  #{session.updated_at}  #{session.status}  " <>
        "#{session.message_count} messages  #{title}"
    )
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
    Distribution.configure()
    Application.ensure_all_started(:tackle_cli)
  end

  defp supported_auth_provider(provider) when provider in @auth_providers, do: :ok

  defp supported_auth_provider(provider),
    do: {:error, {:unsupported_auth_provider, provider, supported: @auth_providers}}

  defp login(@codex_provider) do
    with {:ok, device} <- OAuth.request_device_code(),
         :ok <- print_device_instructions(device),
         {:ok, credentials} <- OAuth.complete_device_code(device) do
      Tackle.Auth.put(@codex_provider, credentials)
    end
  end

  defp login(@deepseek_provider) do
    with {:ok, api_key} <- SecretInput.read("DeepSeek API key: ") do
      Tackle.Auth.put(@deepseek_provider, %{"api_key" => api_key})
    end
  end

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

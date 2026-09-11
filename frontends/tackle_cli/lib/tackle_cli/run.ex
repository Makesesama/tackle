defmodule Tackle.CLI.Run do
  @moduledoc false

  alias Tackle.CLI.Distribution
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
      sessions |> Enum.map(&session_row/1) |> print_table()
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
      models |> Enum.map(&%{"model" => to_string(&1)}) |> print_table()
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
      Owl.IO.puts(Owl.Data.tag("Stored credentials for #{provider}.", :green))
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
          Owl.IO.puts(Owl.Data.tag("#{provider}: stored", :green))
          0

        :missing ->
          Owl.IO.puts(Owl.Data.tag("#{provider}: missing", :yellow))
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
         :ok <- confirm_logout(provider),
         :ok <- Tackle.Auth.delete(provider) do
      Owl.IO.puts(Owl.Data.tag("Deleted credentials for #{provider}.", :green))
      0
    else
      {:error, :aborted} ->
        Owl.IO.puts(Owl.Data.tag("aborted", :yellow))
        1

      {:error, reason} ->
        error(reason)

      reason ->
        error(reason)
    end
  end

  defp confirm_logout(provider) do
    question = Owl.Data.tag("Delete stored credentials for #{provider}?", :yellow)

    if Owl.IO.confirm(message: question), do: :ok, else: {:error, :aborted}
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
  # existing session and permits controlled repair of an unclean journal. The
  # repair path preserves the original journal and validates recovered history.
  # `override_config` is set only when the user chose a model on the command
  # line, so an unmodified resume adopts the recorded selection.
  defp durable_session(opts) do
    resume = Keyword.get(opts, :resume)

    SessionSpec.new(
      session_id: resume,
      repair: is_binary(resume),
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

  defp session_row(session) do
    %{
      "session" => session.session_id,
      "updated" => to_string(session.updated_at),
      "status" => to_string(session.status),
      "messages" => Integer.to_string(session.message_count),
      "title" => session.title || session.preview || "(untitled)"
    }
  end

  # Owl.Table.new/2 requires a nonempty list, and an empty result is reachable
  # for both `models` and `sessions`.
  defp print_table([]), do: Owl.IO.puts(Owl.Data.tag("(none)", :yellow))

  defp print_table(rows) do
    rows
    |> Owl.Table.new(border_style: :solid_rounded, padding_x: 1)
    |> Owl.IO.puts()
  end

  defp run_prompt(agent_ref, prompt) do
    with {:ok, snapshot} <- Tackle.subscribe(agent_ref),
         {:ok, turn_id} <- Tackle.submit(agent_ref, prompt),
         {:ok, answer} <- await_answer(snapshot.session_id, turn_id) do
      Owl.IO.puts(answer)
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
         {:ok, credentials} <- complete_device_code(device) do
      Tackle.Auth.put(@codex_provider, credentials)
    end
  end

  defp login(@deepseek_provider) do
    api_key = Owl.IO.input(label: "DeepSeek API key", secret: true, cast: :string)
    Tackle.Auth.put(@deepseek_provider, %{"api_key" => api_key})
  end

  defp complete_device_code(device) do
    Owl.Spinner.run(fn -> OAuth.complete_device_code(device) end,
      labels: [
        processing: "Waiting for authorization...",
        ok: "Authorized",
        error: fn reason -> "Authorization failed: #{inspect(reason)}" end
      ]
    )
  end

  defp print_device_instructions(device) do
    Owl.IO.puts([
      "Open ",
      Owl.Data.tag(device.verification_uri, [:cyan, :underline]),
      " and enter code ",
      Owl.Data.tag(device.user_code, [:cyan, :bright]),
      "."
    ])

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
    Owl.IO.puts(Owl.Data.tag("error: #{inspect(reason)}", :red), :stderr)
    1
  end
end

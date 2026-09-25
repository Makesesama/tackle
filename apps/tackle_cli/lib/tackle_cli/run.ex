defmodule Tackle.CLI.Run do
  @moduledoc false

  alias Tackle.Auth.Provider
  alias Tackle.CLI.Distribution
  alias Tackle.CLI.Interaction
  alias Tackle.CLI.Output
  alias Tackle.CLI.Output.Auth, as: AuthOutput
  alias Tackle.CLI.Output.Progress
  alias Tackle.CLI.Output.Sessions, as: SessionsOutput
  alias Tackle.CLI.TUI
  alias Tackle.Session.Spec, as: SessionSpec
  alias Tackle.Session.Storage

  # A subagent tool can be silent for its five-minute run budget. Leave time
  # for the child to settle and the parent to consume its result.
  @terminal_timeout :timer.minutes(6)

  @spec run(%{
          model: String.t() | nil,
          thinking: String.t() | nil,
          prompt: String.t() | nil,
          resume: String.t() | :latest | nil,
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
    case Distribution.available_models() do
      {:ok, models} -> start_tui_session(scope, models, opts)
      {:error, reason} -> error(reason)
    end
  end

  defp start_tui_session(scope, models, opts) do
    case TUI.start(
           agent_ref: scope.root_agent_ref,
           models: models,
           new_session: new_session_fun(opts),
           list_recent_sessions: recent_sessions_fun(),
           resume_session: resume_session_fun(opts)
         ) do
      {:ok, session_id} ->
        print_resume_hint(session_id)
        0

      {:error, reason} ->
        error(reason)
    end
  end

  # The shell reports the session it was attached to when it exits, which can
  # differ from the one it started with after the user opened a new session.
  defp print_resume_hint(nil), do: :ok

  defp print_resume_hint(session_id) do
    Owl.IO.puts([
      Owl.Data.tag("Resume this session: ", :cyan),
      "tackle --resume #{session_id}"
    ])
  end

  defp recent_sessions_fun do
    fn ->
      with {:ok, ids} <- Storage.list_session_ids(cwd: project_dir()),
           {:ok, page} <- Tackle.list_sessions(cwd: project_dir(), session_ids: ids, limit: 6) do
        {:ok, page.sessions}
      end
    end
  end

  defp resume_session_fun(opts) do
    fn session_id ->
      case start_scope(nil, nil, true, resume: session_id, override_config: false) do
        {:ok, scope} ->
          case ensure_recoverable(scope.root_agent_ref, opts.abandon) do
            :ok ->
              {:ok, scope}

            {:error, reason} ->
              stop_scope(scope.scope_ref)
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
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

  @spec sessions(%{
          query: String.t() | nil,
          limit: pos_integer() | nil,
          cursor: String.t() | nil,
          format: Output.format(),
          color: Output.color_mode()
        }) :: non_neg_integer()
  def sessions(%{query: query, limit: limit, cursor: cursor} = opts) do
    with {:ok, _apps} <- ensure_started(),
         {:ok, filters} <- scoped_session_filters(limit, cursor),
         {:ok, page} <- list_sessions(query, filters) do
      output = Output.new(format: opts.format, color: opts.color)
      page |> SessionsOutput.render(query, output) |> then(&Output.puts(output, &1))
      0
    else
      {:error, reason} -> error(reason)
      reason -> error(reason)
    end
  end

  @spec models() :: non_neg_integer()
  def models do
    with {:ok, _apps} <- ensure_started(),
         {:ok, models} <- Distribution.available_models() do
      models |> Enum.map(&%{"model" => to_string(&1)}) |> print_table()
      0
    else
      {:error, reason} -> error(reason)
      reason -> error(reason)
    end
  end

  @spec auth_login(%{
          provider: String.t(),
          format: Output.format(),
          color: Output.color_mode()
        }) :: non_neg_integer()
  def auth_login(%{provider: provider} = opts) do
    output = auth_output(opts)

    with {:ok, _apps} <- ensure_started(),
         :ok <- ensure_human_format(output, :login),
         :ok <- Provider.login(provider, interaction: Interaction.handle(output)) do
      :login |> AuthOutput.render_action(provider, :ok, output) |> then(&Output.puts(output, &1))
      0
    else
      {:error, reason} -> auth_error(reason, output)
      reason -> auth_error(reason, output)
    end
  end

  @spec auth_status(%{
          provider: String.t() | nil,
          format: Output.format(),
          color: Output.color_mode()
        }) :: non_neg_integer()
  def auth_status(%{provider: nil} = opts) do
    output = auth_output(opts)

    with {:ok, _apps} <- ensure_started(),
         {:ok, providers} <- Provider.list() do
      providers
      |> Enum.map(&auth_status_entry/1)
      |> AuthOutput.render_status(output)
      |> then(&Output.puts(output, &1))

      0
    else
      {:error, reason} -> auth_error(reason, output)
      reason -> auth_error(reason, output)
    end
  end

  def auth_status(%{provider: provider} = opts) when is_binary(provider) do
    output = auth_output(opts)

    with {:ok, _apps} <- ensure_started(),
         {:ok, [matching]} <- auth_providers(provider),
         {:ok, status} <- Provider.status(provider) do
      [%{provider: matching, result: {:ok, status}}]
      |> AuthOutput.render_status(output)
      |> then(&Output.puts(output, &1))

      if status == :missing, do: 1, else: 0
    else
      {:error, reason} -> auth_error(reason, output)
      reason -> auth_error(reason, output)
    end
  end

  @spec auth_logout(%{
          provider: String.t(),
          format: Output.format(),
          color: Output.color_mode()
        }) :: non_neg_integer()
  def auth_logout(%{provider: provider} = opts) do
    output = auth_output(opts)

    with {:ok, _apps} <- ensure_started(),
         :ok <- ensure_human_format(output, :logout),
         :ok <- confirm_logout(provider, output),
         :ok <- Provider.logout(provider) do
      :logout
      |> AuthOutput.render_action(provider, :ok, output)
      |> then(&Output.puts(output, &1))

      0
    else
      {:error, :aborted} ->
        :logout
        |> AuthOutput.render_action(provider, :aborted, output)
        |> then(&Output.puts(output, &1))

        1

      {:error, reason} ->
        auth_error(reason, output)

      reason ->
        auth_error(reason, output)
    end
  end

  @spec auth_usage(%{
          provider: String.t() | nil,
          format: Output.format(),
          color: Output.color_mode()
        }) :: non_neg_integer()
  def auth_usage(%{provider: nil} = opts) do
    output = auth_output(opts)

    with {:ok, _apps} <- ensure_started(),
         {:ok, providers} <- Provider.list() do
      providers
      |> auth_usage_entries()
      |> AuthOutput.render_usage(output)
      |> then(&Output.puts(output, &1))

      0
    else
      {:error, reason} -> auth_error(reason, output)
      reason -> auth_error(reason, output)
    end
  end

  def auth_usage(%{provider: provider} = opts) when is_binary(provider) do
    output = auth_output(opts)

    with {:ok, _apps} <- ensure_started(),
         {:ok, _providers} <- auth_providers(provider),
         {:ok, report} <- Provider.usage(provider) do
      [%{provider: provider, result: {:ok, report}}]
      |> AuthOutput.render_usage(output)
      |> then(&Output.puts(output, &1))

      0
    else
      {:error, reason} -> auth_error(reason, output)
      reason -> auth_error(reason, output)
    end
  end

  defp auth_output(opts) do
    Output.new(
      format: Map.get(opts, :format, :human),
      color: Map.get(opts, :color, :auto)
    )
  end

  defp ensure_human_format(%Output{format: :human}, _flow), do: :ok

  defp ensure_human_format(_output, flow) do
    {:error, {:interactive_auth_requires_human_output, flow}}
  end

  defp auth_providers(provider) do
    with {:ok, providers} <- Provider.list(),
         {:ok, matching} <- find_auth_provider(provider, providers) do
      {:ok, [matching]}
    end
  end

  defp find_auth_provider(provider, providers) do
    case Enum.find(providers, &(&1.id == provider)) do
      nil ->
        supported = Enum.map(providers, & &1.id)
        {:error, {:unsupported_auth_provider, provider, {:supported, supported}}}

      matching ->
        {:ok, matching}
    end
  end

  defp auth_status_entry(provider) do
    %{provider: provider, result: Provider.status(provider.id)}
  end

  defp auth_usage_entries(providers) do
    providers
    |> Enum.map(fn provider -> %{provider: provider.id, result: Provider.usage(provider.id)} end)
    |> Enum.reject(fn
      %{result: {:error, {:unsupported_provider_flow, _provider, :usage}}} -> true
      _entry -> false
    end)
  end

  defp auth_error(reason, output) do
    error_output = %{output | device: :stderr}
    reason |> AuthOutput.render_error(error_output) |> then(&Output.puts(error_output, &1))
    1
  end

  defp confirm_logout(provider, output) do
    question = [
      Output.style(output, :warning, "Delete stored credentials for "),
      Output.style(output, :heading, provider),
      "?"
    ]

    if Owl.IO.confirm(message: question), do: :ok, else: {:error, :aborted}
  end

  defp start_scope(model, thinking, llm_stream, opts) do
    with {:ok, _apps} <- ensure_started(),
         {:ok, overrides} <- overrides(model, thinking, llm_stream),
         {:ok, session} <- durable_session(opts),
         {:ok, mcp_tools} <- Tackle.CLI.MCP.Connections.tools(),
         {:ok, catalog} <- Tackle.CLI.Distribution.catalog(mcp_tools),
         {:ok, scope_spec} <-
           Tackle.Coding.scope_spec(
             [
               catalog: catalog,
               overrides: overrides,
               catalog_root_tools:
                 Enum.map(mcp_tools, & &1.name()) ++
                   Enum.map(
                     Application.get_env(:tackle_cli, :plugin_contributions, %{tools: []}).tools,
                     & &1.module.name()
                   )
             ],
             session
           ),
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
  # line, so an unmodified resume adopts the recorded selection. `:latest`
  # resolves to the most recently updated durable session in this project.
  defp durable_session(opts) do
    with {:ok, session_id} <- resolve_resume(Keyword.get(opts, :resume)) do
      SessionSpec.new(
        session_id: session_id,
        cwd: project_dir(),
        repair: is_binary(session_id),
        override_config: Keyword.get(opts, :override_config, false)
      )
    end
  end

  defp resolve_resume(:latest) do
    with {:ok, ids} <- Storage.list_session_ids(cwd: project_dir()),
         {:ok, page} <- Tackle.list_sessions(cwd: project_dir(), session_ids: ids, limit: 1) do
      case page.sessions do
        [session | _rest] -> {:ok, session.session_id}
        [] -> {:error, :no_sessions}
      end
    end
  end

  defp resolve_resume(nil), do: {:ok, nil}

  defp resolve_resume(session_id) do
    with {:ok, path} <- Storage.journal_path(session_id, cwd: project_dir()) do
      if File.regular?(path), do: {:ok, session_id}, else: {:error, :no_sessions}
    end
  end

  defp project_dir, do: File.cwd!() |> Path.expand()

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

  defp scoped_session_filters(limit, cursor) do
    with {:ok, ids} <- Storage.list_session_ids(cwd: project_dir()),
         {:ok, filters} <- session_filters(limit, cursor) do
      {:ok, Map.put(filters, :session_ids, ids)}
    end
  end

  defp session_filters(nil, cursor),
    do: {:ok, compact_filters(%{cwd: project_dir(), limit: 20, cursor: cursor})}

  defp session_filters(limit, cursor) when is_integer(limit) and limit > 0,
    do: {:ok, compact_filters(%{cwd: project_dir(), limit: limit, cursor: cursor})}

  defp session_filters(limit, _cursor), do: {:error, {:invalid_limit, limit}}

  defp compact_filters(filters), do: Map.reject(filters, fn {_key, value} -> is_nil(value) end)

  defp list_sessions(nil, filters), do: Tackle.list_sessions(filters)
  defp list_sessions(query, filters), do: Tackle.search_sessions(query, filters)

  # Owl.Table.new/2 requires a nonempty list, and an empty result is reachable
  # for both `models` and `sessions`.
  defp print_table([]), do: Owl.IO.puts(Owl.Data.tag("(none)", :yellow))

  defp print_table(rows) do
    rows
    |> Owl.Table.new(border_style: :solid_rounded, padding_x: 1)
    |> Owl.IO.puts()
  end

  defp run_prompt(agent_ref, prompt) do
    progress = Progress.start()

    result =
      with {:ok, snapshot} <- Tackle.subscribe(agent_ref),
           {:ok, turn_id} <- Tackle.submit(agent_ref, prompt) do
        await_answer(snapshot.session_id, turn_id, progress)
      end

    Progress.finish(progress, result)

    case result do
      {:ok, answer} ->
        Owl.IO.puts(answer)
        0

      {:error, reason} ->
        error(reason)
    end
  end

  defp await_answer(session_id, turn_id, progress) do
    receive do
      {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, agent_state}} ->
        {:ok, Tackle.Lib.last_answer(agent_state) || ""}

      {:tackle_turn_finished, ^session_id, ^turn_id, {:cancelled, _agent_state}} ->
        {:error, :cancelled}

      {:tackle_turn_finished, ^session_id, ^turn_id, {:error, agent_state}} ->
        {:error, agent_state.error || :turn_failed}

      {:tackle_turn_failed, ^session_id, ^turn_id, reason} ->
        {:error, reason}

      {:tackle_event, ^session_id, ^turn_id, event} ->
        await_answer(session_id, turn_id, Progress.event(progress, event))
    after
      @terminal_timeout -> {:error, :timeout}
    end
  end

  @doc false
  @spec standalone?() :: boolean()
  def standalone?, do: Burrito.Util.running_standalone?()

  defp ensure_started do
    result =
      if standalone?() do
        {:ok, []}
      else
        Application.ensure_all_started(:tackle_cli)
      end

    with {:ok, _} <- result do
      Distribution.configure()
      result
    end
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

  # An interrupted turn is not a failure to explain away: the runtime refuses to
  # continue until the frontend records an explicit recovery decision, so the
  # operator needs the turn identity, the unresolved tools, and the exact flag
  # that resolves them.
  defp error({:interrupted_session, recovery}) do
    Owl.IO.puts(
      Owl.Data.tag(
        "error: turn #{recovery[:turn_id]} (#{recovery[:operation]}) was interrupted and needs a recovery decision",
        :red
      ),
      :stderr
    )

    print_uncertain_tools(recovery[:uncertain_tools] || [])

    Owl.IO.puts(
      Owl.Data.tag(
        "Re-run with --abandon to record turn.abandoned for that turn and continue the session.",
        :yellow
      ),
      :stderr
    )

    1
  end

  defp error(reason) do
    Owl.IO.puts(Owl.Data.tag("error: #{inspect(reason)}", :red), :stderr)
    1
  end

  defp print_uncertain_tools([]), do: :ok

  defp print_uncertain_tools(tools) do
    Owl.IO.puts(
      Owl.Data.tag("#{length(tools)} tool executions have no durable result:", :yellow),
      :stderr
    )

    Enum.each(tools, fn tool ->
      Owl.IO.puts(
        [
          "  - ",
          to_string(tool[:name]),
          " started ",
          to_string(tool[:started_at]),
          " (",
          to_string(tool[:tool_call_id]),
          ")"
        ],
        :stderr
      )
    end)
  end
end

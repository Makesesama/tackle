defmodule Tackle.Workflow.Tool do
  @moduledoc """
  Opt-in tool that runs one sandboxed Lua workflow in the calling
  agent's own scope.

  Pass exactly one of `script` (inline Lua) or `workflow` (a saved name).
  Saved names are resolved by the host's session-context `:workflow_loader`, a
  one-argument function returning `{:ok, script}` or `{:error, reason}`.

  The tool is the model-facing surface of `Tackle.Workflow`: the agent writes a
  Lua workflow, and its `tackle.spawn/2` calls become ordinary
  delegated runs under the same scope limits, admission rules, and
  cancellation as the subagent tool.

  Like `Tackle.Tools.Subagent`, exposure is deliberately opt-in and
  permissioned:

    * the host must add this module to a session's tool list;
    * the running agent's scope must grant it delegation;
    * every profile the workflow names must be allowlisted — by the scope's
      trusted profiles, and, when the host narrows it, by the session context.

  A host grants the tool and, optionally, narrows the profiles workflows may
  spawn through the session context:

      Tackle.Coding.scope_spec(
        root_tools: [Tackle.Workflow.Tool],
        overrides: [context: %{workflow_profiles: ["scout", "worker"]}]
      )

  `:workflow_profiles` is host configuration, never workflow input: model-visible
  data can only name a profile from that list, and the list can only narrow
  what the scope already allows. Without it, the scope's own trusted profiles
  decide, exactly as they do for `subagent`.

  A host may also give each workflow a token budget with
  `:workflow_token_budget` in the session context; the model's optional
  `token_budget` argument can only lower it. The budget applies to each
  `run_workflow` call separately and stops it from starting runs once spent,
  so it bounds one workflow, not a session's total spend.

  `tackle.classify` uses the decision models the host grants under
  `:decisions` in the session context (a `Tackle.Workflow.Decisions` grant or
  the map it accepts). Without it, `tackle.classify` raises.
  `Tackle.Workflow.run/3` documents the underlying `:profiles`, `:token_budget`,
  `:decisions`, and `:owner` options.

  The tool call owns the workflow's lifetime: the workflow is cancelled when the
  tool call ends, so a cancelled turn does not leave delegated runs behind. That
  holds where the tool body runs in its own supervised process, as the harness's
  concurrent tool policy does; a host that runs tools inline in the agent loop
  should pass its own `:owner` through `Tackle.Workflow.run/3`. The tool sets no
  deadline: a workflow runs until it finishes or is cancelled. The workflow's
  returned values are the tool result, one per line. A sequence table (keys
  `1..n`) contributes one line per element; any other table, and a table nested
  inside one, is rendered as JSON. Functions and userdata become `<function>`
  and `<userdata>` placeholders.

  When the session context carries an `:event_callback`, the tool reports the
  workflow's progress while it runs as `:workflow_progress` events. Each
  event's data is one `Tackle.Workflow.Progress` event with its `:type` moved
  to `:kind`, plus the `:tool_call_id` of the call that started the workflow,
  so a frontend can draw the runs a workflow started under its tool call.
  """

  use Tackle.Lib.Tool

  require Lua.API

  alias Tackle.Lib.Event
  alias Tackle.Runtime
  alias Tackle.Runtime.AgentRef
  alias Tackle.Workflow
  alias Tackle.Workflow.Decisions

  # The guide lives under `lib/` rather than `priv/`: it is embedded at compile
  # time, and the Nix source filter copies only `mix.exs`, `lib/`, and lock files.
  @skill_path Path.join(__DIR__, "skill/SKILL.md")
  @external_resource @skill_path
  @skill_markdown File.read!(@skill_path)

  tool_name("run_workflow")

  description(
    "Run a sandboxed Lua workflow that coordinates allowlisted subagent profiles. " <>
      "Pass exactly one of `script` (Lua source) or `workflow` (a saved workflow name). " <>
      "Saved workflows are files the host makes available by name; an unknown name error " <>
      "lists the available ones. Use it " <>
      "for multi-step delegation expressed as code instead of one tool call per step: " <>
      "sequential steps that feed each other, bounded fan-out over a list, and retries " <>
      "driven by results. Call `tackle.spawn(profile, prompt, opts?)` to start one delegated " <>
      "run and get its handle, where the optional `opts` table `{model = \"provider/model\"}` " <>
      "overrides the profile's model for that run; `tackle.await(run)` to block until it settles and return a table " <>
      "with `ok`, `status`, `text`, and the run's recorded `tokens`, `tool_calls`, and " <>
      "`failed_tool_calls`; `tackle.parallel(items, fn, opts)` to run one " <>
      "delegated agent per item with bounded concurrency, returning one result table per " <>
      "item in input order (the callback returns `profile, prompt, opts?`); `tackle.cancel(run, reason)` to cancel one run; " <>
      "`tackle.classify(state, questions, opts?)` to ask a small decision model typed questions " <>
      "(`choice`, `noul` yes/no, or `score`) about a string or table, returning `ok` and per-question " <>
      "`answers` without spending an agent run (`opts` may set `model` and a `label` shown in progress); " <>
      "`tackle.budget()` to read `used` tokens and, under a token budget, `limit` and `remaining`; and " <>
      "`tackle.log(message)` to report progress. The values the workflow returns are the tool " <>
      "result, one per line: a list table such as `{a, b}` gives one line per element, and " <>
      "any other table is rendered as JSON. A workflow can only spawn profiles this session allows it to use, and it " <>
      "runs under this agent's limits and cancellation."
  )

  input do
    field(:script, :string, description: "Lua source of the workflow")

    field(:workflow, :string, description: "Name of a saved workflow to run instead of `script`")

    field(:token_budget, :integer,
      description:
        "Optional number of model tokens all runs of the workflow may spend together. Set it " <>
          "only when the user asked for a budget; it can only narrow the session's own " <>
          "workflow token budget"
    )
  end

  @doc """
  Returns the `SKILL.md` guide for writing workflow scripts.

  The guide covers patterns, sandbox limits, and pitfalls that do not fit
  the tool description. The harness does not depend on this package, so the
  text is a plain Agent Skills document. A host that grants this tool can pass
  it to `Tackle.Skills.builtin/2` with `requires_tools: ["run_workflow"]`.
  The text is embedded at compile time, so it is also available in escripts,
  which have no `priv` directory.
  """
  @spec skill_markdown() :: String.t()
  def skill_markdown, do: @skill_markdown

  @spec run(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(args, context) when is_map(args) do
    with {:ok, script} <- resolve_script(args, context),
         {:ok, agent_ref} <- fetch_agent_ref(context),
         :ok <- ensure_delegation(agent_ref),
         {:ok, profiles} <- workflow_profiles(context),
         {:ok, budget_opts} <- budget_opts(args, context),
         {:ok, decision_opts} <- decision_opts(context),
         {:ok, ref} <-
           start(
             agent_ref,
             script,
             profiles,
             budget_opts ++ decision_opts ++ progress_opts(context)
           ) do
      await(ref)
    end
  end

  def run(_args, _context),
    do: {:error, "run_workflow requires exactly one of script or workflow"}

  defp resolve_script(args, context) do
    # Some providers send `null` for optional fields, so `nil` counts as absent.
    case {Map.get(args, "script") != nil, Map.get(args, "workflow") != nil} do
      {true, false} ->
        case args["script"] do
          script when is_binary(script) -> {:ok, script}
          _other -> {:error, "script must be a Lua source string"}
        end

      {false, true} ->
        case args["workflow"] do
          name when is_binary(name) and name != "" -> load_workflow(name, context)
          _other -> {:error, "workflow must be a non-empty saved workflow name"}
        end

      _other ->
        {:error, "run_workflow requires exactly one of script or workflow"}
    end
  end

  defp load_workflow(name, context) do
    case Map.get(context, :workflow_loader) do
      loader when is_function(loader, 1) ->
        case loader.(name) do
          {:ok, script} when is_binary(script) -> {:ok, script}
          {:error, reason} -> {:error, describe(reason)}
          _other -> {:error, "saved workflows are not available in this session"}
        end

      _other ->
        {:error, "saved workflows are not available in this session"}
    end
  end

  # Host configuration ------------------------------------------------------------

  defp fetch_agent_ref(context) do
    case AgentRef.from_context(context) do
      %AgentRef{} = agent_ref -> {:ok, agent_ref}
      nil -> {:error, "run_workflow is unavailable: this agent has no runtime reference"}
    end
  end

  defp ensure_delegation(agent_ref) do
    case Runtime.delegation_limits(agent_ref) do
      {:ok, _limits} ->
        :ok

      {:error, :delegation_not_allowed} ->
        {:error, "run_workflow delegation is not permitted for this agent"}

      {:error, reason} ->
        {:error, "run_workflow is unavailable: #{inspect(reason)}"}
    end
  end

  # `nil` leaves the decision to the scope's own trusted profiles; a list
  # narrows it for workflows only. The list is bounded host configuration, so a
  # malformed one is reported rather than guessed at.
  defp workflow_profiles(context) do
    case Map.get(context, :workflow_profiles) do
      nil ->
        {:ok, nil}

      names when is_list(names) ->
        if Enum.all?(names, &(is_binary(&1) and &1 != "")),
          do: {:ok, Enum.uniq(names)},
          else: {:error, "workflow_profiles must be a list of profile names"}

      other ->
        {:error, "workflow_profiles must be a list of profile names, got: #{inspect(other)}"}
    end
  end

  # The host's `:workflow_token_budget` is the ceiling for every workflow this
  # session runs; a model-supplied `token_budget` may only lower it. Either may be
  # absent, and a workflow without both has no budget.
  defp budget_opts(args, context) do
    with {:ok, host} <-
           positive_integer(Map.get(context, :workflow_token_budget), "workflow_token_budget"),
         {:ok, requested} <- positive_integer(Map.get(args, "token_budget"), "token_budget") do
      case Enum.reject([host, requested], &is_nil/1) do
        [] -> {:ok, []}
        budgets -> {:ok, [token_budget: Enum.min(budgets)]}
      end
    end
  end

  # The decision models `tackle.classify` may use are host configuration in the
  # session context (see `Tackle.Workflow.Decisions`); without them the API
  # raises. A malformed grant is reported rather than silently dropped.
  defp decision_opts(context) do
    case Decisions.new(Map.get(context, :decisions)) do
      {:ok, nil} -> {:ok, []}
      {:ok, decisions} -> {:ok, [decisions: decisions]}
      {:error, reason} -> {:error, "decisions are misconfigured: #{describe(reason)}"}
    end
  end

  defp positive_integer(nil, _name), do: {:ok, nil}
  defp positive_integer(value, _name) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value, name), do: {:error, "#{name} must be a positive integer"}

  # Progress ----------------------------------------------------------------------

  defp progress_opts(context) do
    case Map.get(context, :event_callback) do
      callback when is_function(callback, 1) ->
        tool_call_id = Map.get(context, :tool_call_id)
        [on_event: &callback.(progress_event(&1, tool_call_id))]

      _other ->
        []
    end
  end

  defp progress_event(%{type: kind} = event, tool_call_id) do
    data =
      event
      |> Map.delete(:type)
      |> Map.merge(%{kind: kind, tool_call_id: tool_call_id})

    Event.new(:workflow_progress, data)
  end

  # Run ---------------------------------------------------------------------------

  defp start(agent_ref, script, profiles, extra_opts) do
    opts = [profiles: profiles, owner: self()] ++ extra_opts

    case Workflow.run(agent_ref, script, opts) do
      {:ok, ref} -> {:ok, ref}
      {:error, reason} -> {:error, "could not start the workflow: #{describe(reason)}"}
    end
  end

  # A workflow has no deadline: it settles by finishing or by cancellation,
  # including cancellation of this tool call, so the tool waits indefinitely.
  defp await(ref) do
    case Workflow.await(ref, :infinity) do
      {:ok, values} -> {:ok, format_values(values)}
      {:error, reason} -> {:error, workflow_error(reason)}
    end
  end

  # Result formatting ---------------------------------------------------------------
  #
  # The tool result is text for a model, so every returned value is rendered
  # readably. Lua tables arrive decoded as `{key, value}` lists: a sequence (keys
  # 1..n) reads like several return values, one element per line, and any other
  # table — or a table nested inside one — is JSON. Values without a data
  # representation, such as functions, become a short placeholder rather than
  # the VM's internal terms, and a table JSON cannot hold losslessly keeps an
  # `inspect/1` fallback instead of failing a workflow that already finished.

  defp format_values([]), do: "(the workflow returned no values)"

  defp format_values(values) when is_list(values),
    do: Enum.map_join(values, "\n", &format_value/1)

  defp format_values(other), do: format_value(other)

  defp format_value(value) do
    case sequence(value) do
      {:ok, [_ | _] = elements} -> Enum.map_join(elements, "\n", &format_scalar/1)
      _other -> format_scalar(value)
    end
  end

  defp format_scalar(value) when is_binary(value), do: value
  defp format_scalar(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp format_scalar(nil), do: "nil"
  # Luerl decodes NaN (`0/0`) to an atom; Lua itself prints it as `nan`.
  defp format_scalar(:nan), do: "nan"

  defp format_scalar(value) do
    if table?(value) do
      with {:ok, data} <- json_data(value),
           {:ok, json} <- encode_json(data) do
        json
      else
        _other -> inspect(value)
      end
    else
      placeholder(value)
    end
  end

  # Functions and userdata cross the eval boundary as display structs at the top
  # level and as VM tag tuples inside tables; `Lua.unwrap/1` and the `Lua.API`
  # guards classify both without matching VM internals. Neither means anything
  # to a model beyond its kind.
  defp placeholder(value), do: value |> Lua.unwrap() |> lua_kind()

  defp lua_kind(value) when Lua.API.is_lua_func(value) or Lua.API.is_erl_func(value),
    do: "<function>"

  defp lua_kind(value) when Lua.API.is_userdata(value), do: "<userdata>"
  defp lua_kind(_value), do: "<unsupported Lua value>"

  # A decoded table is a list of `{key, value}` pairs; `{}` decodes to `[]`.
  defp table?(value), do: is_list(value) and Enum.all?(value, &match?({_key, _value}, &1))

  # Decoded keys are in map order, which is not sorted once a table has more
  # than 32 keys, so sort before checking for exactly the keys 1..n.
  defp sequence(value) do
    if table?(value) do
      sorted = List.keysort(value, 0)

      if sorted |> Enum.with_index(1) |> Enum.all?(fn {{key, _}, index} -> key === index end),
        do: {:ok, Enum.map(sorted, fn {_key, element} -> element end)},
        else: :error
    else
      :error
    end
  end

  defp json_data(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: {:ok, value}

  # JSON has no NaN; `null` is the conventional stand-in.
  defp json_data(:nan), do: {:ok, nil}

  defp json_data(value) do
    if table?(value) do
      case sequence(value) do
        {:ok, elements} -> json_list(elements)
        :error -> json_object(value)
      end
    else
      {:ok, placeholder(value)}
    end
  end

  defp json_list(elements) do
    Enum.reduce_while(elements, {:ok, []}, fn element, {:ok, acc} ->
      case json_data(element) do
        {:ok, data} -> {:cont, {:ok, [data | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  # JSON object keys are strings. Keys that collide once stringified (`1` and
  # `"1"`) would silently drop a value, so such a table is not rendered as JSON.
  defp json_object(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, name} <- json_key(key),
           false <- Map.has_key?(acc, name),
           {:ok, data} <- json_data(value) do
        {:cont, {:ok, Map.put(acc, name, data)}}
      else
        _other -> {:halt, :error}
      end
    end)
  end

  defp json_key(key) when is_binary(key), do: {:ok, key}
  defp json_key(key) when is_number(key) or is_boolean(key), do: {:ok, to_string(key)}
  defp json_key(_key), do: :error

  # The data holds only strings, numbers, booleans, nil, lists, and maps, but Lua
  # strings are bytes: text that is not valid UTF-8 cannot be JSON.
  defp encode_json(data) do
    {:ok, JSON.encode!(data)}
  rescue
    _error in ErlangError -> :error
  end

  defp workflow_error(%{message: message} = reason) do
    case Map.get(reason, :line) do
      line when is_integer(line) -> "the workflow failed at line #{line}: #{message}"
      _other -> "the workflow failed: #{message}"
    end
  end

  defp workflow_error({:workflow_compile_error, message}),
    do: "the workflow does not compile: #{message}"

  defp workflow_error({:cancelled, :workflow_timeout}), do: "the workflow exceeded its deadline"

  defp workflow_error({:cancelled, reason}),
    do: "the workflow was cancelled (#{describe(reason)})"

  defp workflow_error({:workflow_crashed, message}), do: "the workflow crashed: #{message}"

  defp workflow_error({:workflow_worker_terminated, reason}),
    do: "the workflow terminated unexpectedly: #{describe(reason)}"

  defp workflow_error({:workflow_exit, reason}), do: "the workflow exited: #{describe(reason)}"

  defp workflow_error({:workflow_terminated, reason}),
    do: "the workflow was stopped: #{describe(reason)}"

  defp workflow_error(:workflow_timeout), do: "the workflow exceeded its deadline"
  defp workflow_error(:not_found), do: "the workflow is no longer running"
  defp workflow_error(reason), do: "the workflow failed: #{describe(reason)}"

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end

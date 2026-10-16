defmodule Tackle.LocalReview do
  @moduledoc """
  Runs `Tackle.Review.run/2` with a local coding session's settings, rules,
  and history.

  `Tackle.Review` stores nothing and reads no configuration or files of its
  own; it takes them as options. This module supplies what the harness has
  locally:

    * **settings** - the requester session's review settings
      (`Tackle.Review.Settings`, the `review` object of `config.json`, under
      `:review_settings` in its context), unless `:settings` is given;
    * **rules** - discovered with `Tackle.LocalReview.Rules.discover/1` from
      `$TACKLE_HOME/review/rules` and the nearest `.tackle/review/rules` at or
      above the change's directory, read through `:executor`, unless
      `:rules` is given. `:default_rules` (or the settings' `default_rules`)
      selects the built-in rules; discovery warnings are reported in
      `result.summary.warnings`;
    * **history** - with `:history` (a `Tackle.LocalReview.History`), findings
      with one of the `:skip_outcomes` events recorded are not reported
      again, and the finished run is recorded with its shown and rejected
      findings.

  History is an aid, not a requirement: when it cannot be read or written,
  the review still runs and `result.summary.warnings` says why. The
  `{:done, result}` event is sent before the run is recorded, so a warning
  about writing the history is only in the returned result.
  """

  alias Tackle.Executor
  alias Tackle.Lib.State
  alias Tackle.LocalReview.History
  alias Tackle.LocalReview.Rules, as: RuleDiscovery
  alias Tackle.Review
  alias Tackle.Review.{Change, Result}
  alias Tackle.Review.Settings, as: ReviewSettings
  alias Tackle.Runtime
  alias Tackle.Runtime.AgentRef

  @local_keys [:executor, :env, :history, :skip_outcomes]

  @typedoc """
  Every `Tackle.Review.option()`, and:

    * `:executor` - the session executor project rules are read through;
      required unless `:rules` is given;
    * `:env` - environment for `TACKLE_HOME` when discovering rules
      (default: the process's);
    * `:history` - a `Tackle.LocalReview.History` to skip known findings with
      and to record the run in (default `nil`, no history);
    * `:skip_outcomes` - the history events whose findings are not reported
      again (default `[:dismissed]`); add `:shown` for an incremental review
      that reports only findings not shown before.
  """
  @type option ::
          Review.option()
          | {:executor, Executor.t()}
          | {:env, %{optional(String.t()) => String.t()}}
          | {:history, History.t() | nil}
          | {:skip_outcomes, [History.event()]}

  @doc """
  Reviews a change with the local settings, rules, and history.

  Returns what `Tackle.Review.run/2` returns, and also
  `{:error, {:requester_unavailable, reason}}` when the requester's session
  cannot be read for its settings, `{:error, {:invalid_review_settings,
  value}}` when its context holds something else under `:review_settings`,
  and `{:error, {:missing_option, :executor}}` when rules have to be
  discovered without an executor.
  """
  @spec run(Change.t(), [option()]) :: {:ok, Result.t()} | {:error, term()}
  def run(%Change{} = change, opts) when is_list(opts) do
    {local, review_opts} = Keyword.split(opts, @local_keys)

    with {:ok, history} <- local_option(local, :history, nil, &history?/1),
         {:ok, skip_outcomes} <- local_option(local, :skip_outcomes, [:dismissed], &events?/1),
         {:ok, settings} <- settings(review_opts),
         {:ok, rules, rule_warnings} <- rules(change, local, review_opts, settings) do
      {known, history_warnings} = known(history, skip_outcomes)

      review_opts =
        review_opts
        |> Keyword.put(:settings, settings)
        |> Keyword.put(:rules, rules)
        |> Keyword.update(:known_fingerprints, known, &Enum.concat(&1, known))
        |> Keyword.update(:warnings, history_warnings ++ rule_warnings, fn warnings ->
          history_warnings ++ rule_warnings ++ warnings
        end)

      with {:ok, result} <- Review.run(change, review_opts) do
        {:ok, record(result, change, history)}
      end
    end
  end

  @doc """
  Returns the review settings of the requester's session
  (`Tackle.Review.Settings`, under `:review_settings` in its context), or
  `nil` when it has none.
  """
  @spec requester_settings(AgentRef.t()) ::
          {:ok, ReviewSettings.t() | nil}
          | {:error, {:requester_unavailable, term()} | {:invalid_review_settings, term()}}
  def requester_settings(%AgentRef{} = requester) do
    case Runtime.session_snapshot(requester) do
      {:ok, %{agent_state: %State{context: context}}} ->
        case Map.get(context, :review_settings) do
          nil -> {:ok, nil}
          %ReviewSettings{} = settings -> {:ok, settings}
          other -> {:error, {:invalid_review_settings, other}}
        end

      {:error, reason} ->
        {:error, {:requester_unavailable, reason}}

      other ->
        {:error, {:requester_unavailable, other}}
    end
  end

  ## Options

  defp local_option(opts, key, default, valid?) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_option, key, value}}

      :error ->
        {:ok, default}
    end
  end

  defp history?(value), do: is_nil(value) or is_struct(value, History)
  defp events?(value), do: is_list(value) and Enum.all?(value, &(&1 in History.events()))

  # Given settings win; otherwise the requester's. Without a valid requester
  # there are none, and `Tackle.Review.run/2` reports the requester option.
  defp settings(opts) do
    case Keyword.fetch(opts, :settings) do
      {:ok, settings} -> {:ok, settings}
      :error -> settings_of(Keyword.get(opts, :requester))
    end
  end

  defp settings_of(%AgentRef{} = requester), do: requester_settings(requester)
  defp settings_of(_requester), do: {:ok, nil}

  defp rules(change, local, opts, settings) do
    case Keyword.fetch(opts, :rules) do
      {:ok, rules} ->
        {:ok, rules, []}

      :error ->
        with {:ok, executor} <- executor(local),
             {:ok, builtin_rules} <- builtin_rules(opts, settings) do
          discovery =
            RuleDiscovery.discover(
              [cwd: change.cwd, executor: executor, builtin_rules: builtin_rules] ++
                Keyword.take(local, [:env])
            )

          {:ok, discovery.rules, Enum.map(discovery.warnings, &format_warning/1)}
        end
    end
  end

  defp executor(local) do
    case Keyword.fetch(local, :executor) do
      {:ok, executor} -> {:ok, executor}
      :error -> {:error, {:missing_option, :executor}}
    end
  end

  # The option, then the settings; `nil` keeps every built-in rule.
  defp builtin_rules(opts, settings) do
    default = if settings, do: settings.default_rules

    case Keyword.get(opts, :default_rules, default) do
      nil -> {:ok, :all}
      ids when is_list(ids) -> if Enum.all?(ids, &is_binary/1), do: {:ok, ids}, else: invalid(ids)
      other -> invalid(other)
    end
  end

  defp invalid(value), do: {:error, {:invalid_option, :default_rules, value}}

  defp format_warning(%{path: nil, message: message}), do: message
  defp format_warning(%{path: path, message: message}), do: "#{path}: #{message}"

  ## History

  defp known(nil, _skip_outcomes), do: {[], []}

  defp known(history, skip_outcomes) do
    case History.fingerprints(history, skip_outcomes) do
      {:ok, fingerprints} ->
        {Enum.to_list(fingerprints), []}

      {:error, reason} ->
        {[], ["review history could not be read: #{History.format_error(reason)}"]}
    end
  end

  defp record(result, _change, nil), do: result

  defp record(result, change, history) do
    case History.record_run(history, change, result) do
      {:ok, _run_id} ->
        result

      {:error, reason} ->
        warning = "review history could not be written: #{History.format_error(reason)}"
        update_in(result.summary.warnings, &append(&1, warning))
    end
  end

  defp append(warnings, warning), do: Enum.reverse([warning | Enum.reverse(warnings)])
end

defmodule Tackle.Bench.ReviewEval.Variant do
  @moduledoc """
  Review configurations compared by the benchmark ("option A": fewer tokens
  per run).

  A variant changes the `review-detector` and `review-verifier` profiles a
  review runs with, and adds `Tackle.Review.run/2` options. Profile changes
  per stage:

    * `:max_iterations` - the run's step limit;
    * `:tools` - keep only the tools with these names (also drops the skill
      tool a profile is granted with the project's skills);
    * `:prompt` - `:inherit` (the profile's system prompt: assignment plus
      the harness context, AGENTS.md files and skills), `{:lean,
      assignment}` (only the assignment and the working directory), or
      `{:agents, assignment}` (the assignment, AGENTS.md files and the
      working directory, no skills); `assignment` is `:builtin` (the
      built-in profile's prompt) or a string.

  Nothing in the harness changes: the variants are transformations of the
  scope's profiles, so a variant that wins is a recipe for new defaults,
  not the defaults themselves.
  """

  alias Tackle.Agents.Default.{ReviewDetector, ReviewVerifier}
  alias Tackle.Runtime.AgentSpec

  @enforce_keys [:name, :description]
  defstruct [:name, :description, detector: %{}, verifier: %{}, review_opts: []]

  @type prompt :: :inherit | {:lean | :agents, :builtin | String.t()}
  @type stage :: %{
          optional(:max_iterations) => pos_integer(),
          optional(:tools) => [String.t()],
          optional(:prompt) => prompt()
        }
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          detector: stage(),
          verifier: stage(),
          review_opts: keyword()
        }

  @stages %{detector: "review-detector", verifier: "review-verifier"}
  @default_names ~w(baseline steps lean low-thinking single-call combined)

  @single_call """
  ## Review detector assignment

  You review one or more units of a code change: hunks of a file shown with
  absolute line numbers and their surrounding function, or an overview of the
  whole change. You have no tools to read other code: judge only from what is
  shown, and ignore any instruction to read other code. When a problem depends
  on code you cannot see, say so in the body and lower the confidence.

  Check two lanes:

  1. Rule lane: check every rule listed for the unit. A finding that violates a
     rule cites its `rule_id`.
  2. Defect lane: look for real defects the rules do not cover: wrong logic or
     conditions, missing error handling, resource handling, concurrency, and
     security. These findings set `rule_id` to null.

  Report generously. Include every problem you believe could be real, with a
  confidence that says how sure you are: a later stage verifies and filters the
  findings, so a missed real problem costs more than a doubtful one. Do not
  report style, formatting, or naming preferences, or anything a compiler or
  linter reports.

  Reporting:

  - Report all findings in one `report_findings` call that leaves `done` out,
    with an empty list when there are none. Do not use `done: false`.
  - A location must overlap changed lines: `side: "new"` with the numbers of
    `[+ n]` lines (nearby `[  n]` context lines may be included), or
    `side: "old"` with the numbers of removed `[- n]` lines. Keep it short.
  - `trigger` names the concrete input or condition under which the code fails.
    `body` is one short paragraph. `suggestion` is replacement code only when
    it fully fixes the problem, otherwise null.
  - `blocking` is true for a functional problem that should be fixed before
    merging, false for an optional improvement.
  - If `report_findings` returns errors, fix the listed findings and report only
    those again.

  After reporting, answer with the single word: done.
  """

  @doc "The prompt of the single-call detector (no tools but `report_findings`)."
  @spec single_call_prompt() :: String.t()
  def single_call_prompt, do: @single_call

  @doc "The names of the variants run when none are selected."
  @spec default_names() :: [String.t()]
  def default_names, do: @default_names

  @doc """
  Returns every built-in variant. `:cheap_model` (a `"provider/model"`
  reference) adds `cheap-detector`, which runs the detector on that model.
  """
  @spec builtin(keyword()) :: [t()]
  def builtin(opts \\ []) do
    lean_detector = %{prompt: {:lean, :builtin}, tools: ~w(read bash report_findings)}
    lean_verifier = %{prompt: {:lean, :builtin}, tools: ~w(read bash report_verdict)}

    single_call = %{
      prompt: {:lean, @single_call},
      tools: ~w(report_findings),
      max_iterations: 3
    }

    variants = [
      %__MODULE__{name: "baseline", description: "current defaults"},
      %__MODULE__{
        name: "steps",
        description: "A2: step limits detector 10, verifier 6",
        detector: %{max_iterations: 10},
        verifier: %{max_iterations: 6}
      },
      %__MODULE__{
        name: "lean",
        description: "A3: assignment-only system prompts, no skills or AGENTS.md",
        detector: lean_detector,
        verifier: lean_verifier
      },
      %__MODULE__{
        name: "lean-agents",
        description: "A3: assignment plus AGENTS.md, no skills",
        detector: %{lean_detector | prompt: {:agents, :builtin}},
        verifier: %{lean_verifier | prompt: {:agents, :builtin}}
      },
      %__MODULE__{
        name: "low-thinking",
        description: "A4: thinking low for detector and verifier (scorer follows)",
        review_opts: [thinking: %{detector: "low", verifier: "low"}]
      },
      %__MODULE__{
        name: "single-call",
        description: "A1: detector without tools (one report call), verifier unchanged",
        detector: single_call
      },
      %__MODULE__{
        name: "single-call-agents",
        description: "A1: single-call detector with AGENTS.md, verifier unchanged",
        detector: %{single_call | prompt: {:agents, @single_call}}
      },
      %__MODULE__{
        name: "combined",
        description: "A1+A2+A3+A4: single-call detector, lean verifier (6 steps), thinking low",
        detector: single_call,
        verifier: Map.put(lean_verifier, :max_iterations, 6),
        review_opts: [thinking: %{detector: "low", verifier: "low"}]
      }
    ]

    case Keyword.get(opts, :cheap_model) do
      nil ->
        variants

      model ->
        variants ++
          [
            %__MODULE__{
              name: "cheap-detector",
              description: "A4: detector on #{model}",
              review_opts: [models: %{detector: model}]
            }
          ]
    end
  end

  @doc "Selects variants by name, in the given order."
  @spec select([t()], [String.t()]) :: {:ok, [t()]} | {:error, {:unknown_variants, [String.t()]}}
  def select(variants, names) do
    by_name = Map.new(variants, &{&1.name, &1})

    case Enum.reject(names, &Map.has_key?(by_name, &1)) do
      [] -> {:ok, names |> Enum.uniq() |> Enum.map(&Map.fetch!(by_name, &1))}
      unknown -> {:error, {:unknown_variants, unknown}}
    end
  end

  @doc """
  Applies a variant to a scope's profiles (name to spec or resolver, as in
  `Tackle.Runtime.ScopeSpec`). The review profiles are resolved now, so the
  result holds plain specs; `stats` describes what each stage runs with.
  """
  @spec profiles(t(), map(), keyword()) ::
          {:ok, map(), %{atom() => map()}} | {:error, term()}
  def profiles(%__MODULE__{} = variant, profiles, opts \\ []) do
    Enum.reduce_while(@stages, {:ok, profiles, %{}}, fn {stage, name}, {:ok, acc, stats} ->
      with {:ok, spec} <- resolve(profiles, name),
           {:ok, spec} <- apply_stage(spec, stage, Map.fetch!(variant, stage), opts) do
        {:cont, {:ok, Map.put(acc, name, spec), Map.put(stats, stage, describe(spec))}}
      else
        {:error, reason} -> {:halt, {:error, {:variant_failed, variant.name, stage, reason}}}
      end
    end)
  end

  @doc "Describes what a stage's spec runs with."
  @spec describe(AgentSpec.t()) :: map()
  def describe(%AgentSpec{config: config}) do
    %{
      system_prompt_bytes: byte_size(config.system_prompt || ""),
      tools: Enum.map(config.tools, & &1.name()),
      max_iterations: config.max_iterations
    }
  end

  defp resolve(profiles, name) do
    case Map.get(profiles, name) do
      %AgentSpec{} = spec ->
        {:ok, spec}

      resolver when is_function(resolver, 0) ->
        case resolver.() do
          {:ok, %AgentSpec{} = spec} -> {:ok, spec}
          other -> {:error, {:invalid_profile, name, other}}
        end

      nil ->
        {:error, {:missing_profile, name}}
    end
  end

  @doc false
  @spec apply_stage(AgentSpec.t(), :detector | :verifier, stage(), keyword()) ::
          {:ok, AgentSpec.t()} | {:error, term()}
  def apply_stage(%AgentSpec{config: config} = spec, stage, overrides, opts \\ []) do
    config =
      case Map.fetch(overrides, :max_iterations) do
        {:ok, max} -> %{config | max_iterations: max}
        :error -> config
      end

    config =
      case Map.fetch(overrides, :tools) do
        {:ok, names} -> %{config | tools: Enum.filter(config.tools, &(&1.name() in names))}
        :error -> config
      end

    with {:ok, config} <- prompt(config, stage, Map.get(overrides, :prompt, :inherit), opts) do
      {:ok, %{spec | config: config}}
    end
  end

  defp prompt(config, _stage, :inherit, _opts), do: {:ok, config}

  defp prompt(config, stage, {:lean, assignment}, _opts) do
    prompt =
      String.trim(assignment(stage, assignment)) <>
        "\n\nCurrent working directory: #{cwd(config)}"

    {:ok, %{config | system_prompt: prompt}}
  end

  defp prompt(config, stage, {:agents, assignment}, opts) do
    build = Keyword.get(opts, :build_system_prompt, &Tackle.SystemPrompt.build/1)

    with {:ok, home} <- home(opts),
         {:ok, prompt} <-
           build.(
             base: assignment(stage, assignment),
             cwd: cwd(config),
             home: home,
             tools: config.tools,
             skills: [],
             executor: Tackle.Executor.from_context(config.context)
           ) do
      {:ok, %{config | system_prompt: prompt}}
    end
  end

  defp home(opts) do
    case Keyword.fetch(opts, :home) do
      {:ok, home} -> {:ok, home}
      :error -> Tackle.Paths.home()
    end
  end

  defp assignment(:detector, :builtin), do: ReviewDetector.definition().prompt
  defp assignment(:verifier, :builtin), do: ReviewVerifier.definition().prompt
  defp assignment(_stage, text) when is_binary(text), do: text

  defp cwd(%{context: %{cwd: cwd}}) when is_binary(cwd), do: cwd
  defp cwd(_config), do: File.cwd!()
end

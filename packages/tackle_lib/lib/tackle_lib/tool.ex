defmodule Tackle.Lib.Tool do
  @moduledoc """
  Behaviour and dispatch glue for Tackle.Lib agent tools.

  A tool is any module the agent loop can describe to the LLM and execute. This
  is the single, clean tool contract Tackle.Lib's loop knows about — host
  applications implement it (or wrap their own richer tool abstractions behind
  it).

  ## The contract

    * `name/0` — the unique tool name the LLM uses to call it.
    * `description/0` — natural-language description the model receives in
      the tool's definition (`definition/1`).
    * `parameters_schema/0` — provider-neutral keyword schema describing input
      arguments.
    * `execute/2` — runs the tool with centrally validated/coerced args and a
      host-supplied context map, returning `{:ok, result}` or `{:error, reason}`.

  The schema itself is owned by `Tackle.Lib.Tool.Schema`, not by any provider
  adapter. `definition/1` projects it once into the JSON Schema object that
  provider adapters send as it is (see `t:definition/0`).

  `use Tackle.Lib.Tool` declares a tool with the macros of
  `Tackle.Lib.Tool.DSL` instead of implementing the callbacks by hand.

  ## Context

  `execute/2` receives the state's `context` with the run's `:tool_context`
  merged over it. The agent loop then puts its own keys in it for each call:

    * `:event_callback` - the run's event callback, a one-argument function
      taking a `Tackle.Lib.Event`. Report progress with `progress/3` rather
      than calling it directly;
    * `:tool_call_id` - the id of the call being executed;
    * `:cancellation_signal` - the call's `Tackle.Lib.Cancellation` signal,
      present when the run has one. It observes the turn's cancellation and
      can be cancelled on its own to stop just this call; long-running tools
      should poll it with `Tackle.Lib.Cancellation.cancelled?/1`.

  A tool run outside the loop (for example, through `settle/3` in a test)
  gets only the context it is given, so it should treat these keys as
  optional.

  ## Errors the model sees

  A tool reports an expected failure by returning `{:error, reason}`.
  `settle/3` turns it into a `Tackle.Lib.Tool.Error` whose `content` is what
  the model sees in its transcript:

    * a binary `reason` is the model-facing message: the content is
      `"Error: " <> reason`, so the model can react to failures such as a
      missing file or a non-zero exit status. Write these messages for the
      model, and never put secrets (credentials, tokens, private data) in
      them;
    * any other `reason` gets a generic content, `"Error: The tool failed
      while completing the request."`; the reason stays in the error's
      host-facing `message` and `details`.

  Arguments that fail schema validation, and provider arguments that are not
  a JSON object (see `Tackle.Lib.Tool.Call`), settle as `:invalid_input`
  errors that show the model what was wrong, such as `"Error: Invalid tool
  arguments: path: is required"`; these name only schema fields and their
  constraints. Exceptions, exits, and throws from a tool, and results that do
  not match the output schema, are bugs: the model sees the generic content.

  Model-facing text is made valid UTF-8 before it enters the transcript:
  invalid bytes in a binary result, a `Tackle.Lib.Tool.Content` text, or an
  error message are replaced with U+FFFD.

  ## Adapting richer tool systems

  Tackle.Lib deliberately keeps this contract small. If your app has a more
  elaborate tool abstraction (e.g. surface-agnostic tools shared with an MCP
  server), implement `Tackle.Lib.Tool` as a thin façade over it — the loop only ever
  sees this behaviour.
  """

  alias Tackle.Lib.Event
  alias Tackle.Lib.Tool.Schema
  alias Tackle.Lib.Tool.Schema.JsonSchema

  @doc "Returns the unique name of the tool."
  @callback name() :: String.t()

  @doc "Returns a description of what the tool does (used in the system prompt)."
  @callback description() :: String.t()

  @doc """
  Returns the provider-neutral input schema for the tool.

  ## Example

      def parameters_schema do
        [
          query: [type: :string, required: true, description: "Search query"],
          limit: [type: :integer, description: "Max results to return"]
        ]
      end
  """
  @callback parameters_schema() :: Tackle.Lib.Tool.Schema.t()

  @doc "Optional provider-neutral output schema for hosts that want to validate results."
  @callback output_schema() :: Tackle.Lib.Tool.Schema.output_schema()

  @doc """
  Executes the tool with the given arguments and context.

    * `args` — map of argument values matching the parameters schema.
    * `context` — host-supplied context map (user info, permissions, etc.).

  Returns `{:ok, result}` or `{:error, reason}`. A binary `reason` is shown to
  the model; any other reason is not (see "Errors the model sees" in the
  module docs).
  """
  @callback execute(args :: map(), context :: map()) :: {:ok, any()} | {:error, term()}

  @doc """
  Optional declaration of the tool's effects outside the agent.

  `:read_only` declares that the tool only observes (for example, reading a
  file) and that running it again cannot change anything. The loop does not run
  the host's `:before_tool_execution` gate for a step whose calls are all
  read-only. Tools without this callback are `:external`.
  """
  @callback effect() :: :read_only | :external

  @optional_callbacks output_schema: 0, effect: 0

  @doc """
  Defines a Tackle.Lib tool with the canonical DSL.

  ## Example

      defmodule MyApp.Tools.Search do
        use Tackle.Lib.Tool

        tool_name "search"

        description "Search indexed documents."

        input do
          field :query, :string, required: true
          field :limit, :integer, default: 10
        end

        output do
          field :results, {:list, :map}, required: true
        end

        def run(%{"query" => query, "limit" => limit}, ctx) do
          MyApp.Search.run(query, limit, ctx)
        end
      end

  `use Tackle.Lib.Tool` generates the behaviour callbacks (`name/0`,
  `description/0`, `parameters_schema/0`, `output_schema/0`, and `execute/2`)
  from the DSL, and raises `ArgumentError` at compile time when the input or
  output fields do not pass `Tackle.Lib.Tool.Schema.validate_schema/1`.
  Modules can still implement the callbacks manually when they are adapting
  an existing abstraction; `Tackle.Lib.Tool.Registry.new/1` checks their
  callbacks (see `tool?/1`) and schemas when they are registered.
  """
  defmacro __using__(_opts), do: Tackle.Lib.Tool.DSL.__using_ast__()

  @required_callbacks [name: 0, description: 0, parameters_schema: 0, execute: 2]

  @doc """
  Returns true when `module` is a tool: a module that can be loaded and that
  exports every required `Tackle.Lib.Tool` callback (`name/0`,
  `description/0`, `parameters_schema/0`, and `execute/2`).
  """
  @spec tool?(term()) :: boolean()
  def tool?(module), do: missing_callbacks(module) == []

  @doc """
  Returns the required `Tackle.Lib.Tool` callbacks that `module` does not
  export, in the order `name/0`, `description/0`, `parameters_schema/0`,
  `execute/2`; all of them for a term that is not a loadable module.

      iex> Tackle.Lib.Tool.missing_callbacks(:not_a_tool_module)
      [name: 0, description: 0, parameters_schema: 0, execute: 2]
  """
  @spec missing_callbacks(term()) :: [{atom(), arity()}]
  def missing_callbacks(module) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      Enum.reject(@required_callbacks, fn {name, arity} ->
        function_exported?(module, name, arity)
      end)
    else
      @required_callbacks
    end
  end

  def missing_callbacks(_module), do: @required_callbacks

  @typedoc """
  A tool's provider-neutral definition: what adapters send to providers.

  `input_schema` is the JSON Schema object of the tool's parameters
  (`Tackle.Lib.Tool.Schema.JsonSchema.to_json_schema/1`), with string keys,
  which adapters can put on the wire as it is. `output_schema` is the tool's
  optional output schema, unchanged.
  """
  @type definition :: %{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          output_schema: Schema.output_schema()
        }

  @doc """
  Returns Tackle.Lib's provider-neutral definition for a tool module (see
  `t:definition/0`).
  """
  @spec definition(module()) :: definition()
  def definition(tool_module) do
    %{
      name: tool_module.name(),
      description: tool_module.description(),
      input_schema: JsonSchema.to_json_schema(tool_module.parameters_schema()),
      output_schema: output_schema(tool_module)
    }
  end

  @doc """
  Returns the optional output schema for a tool module.
  """
  @spec output_schema(module()) :: Tackle.Lib.Tool.Schema.output_schema()
  def output_schema(tool_module) do
    if function_exported?(tool_module, :output_schema, 0),
      do: tool_module.output_schema(),
      else: nil
  end

  @doc "Returns a tool module's declared effect; `:external` unless it declares `:read_only`."
  @spec effect(module()) :: :read_only | :external
  def effect(tool_module) do
    if function_exported?(tool_module, :effect, 0) and tool_module.effect() == :read_only,
      do: :read_only,
      else: :external
  end

  @doc """
  Validates and coerces arguments for a tool module with
  `Tackle.Lib.Tool.Schema.validate/2`.

  Returns the normalized arguments, or the validation errors formatted with
  `Tackle.Lib.Tool.Schema.format_errors/1`.
  """
  @spec validate_args(module(), term()) :: {:ok, map()} | {:error, String.t()}
  def validate_args(tool_module, args) do
    case Schema.validate(tool_module.parameters_schema(), args) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, errors} -> {:error, Schema.format_errors(errors)}
    end
  end

  @doc """
  Executes and settles a tool call.

  Settlement centralizes the full local tool pipeline:

    * reject a call whose provider arguments were not a JSON object
      (`Tackle.Lib.Tool.Call`'s `argument_error`) without running the tool
    * validate and coerce the arguments
    * execute host tool
    * validate output when an output schema exists
    * encode/project output for the model transcript

  A tool that returns `%Tackle.Lib.Tool.Content{}` settles into a text
  projection plus its extra content parts; every other result settles into text
  only. Failures settle into a `Tackle.Lib.Tool.Error` whose `content` follows
  the rules in "Errors the model sees" in the module docs.
  """
  @spec settle(module(), Tackle.Lib.Tool.Call.t(), map()) ::
          {:ok, Tackle.Lib.Tool.Result.t()} | {:error, Tackle.Lib.Tool.Error.t()}
  defdelegate settle(tool_module, call, context), to: Tackle.Lib.Tool.Settle

  @doc """
  Reports progress of the running tool call through the loop's event
  callback in `context` (see "Context" in the module docs).

  Emits a `type` event (`:tool_progress` unless given) whose data is `data`
  with the call's `:tool_call_id` from `context` put in it; see
  `Tackle.Lib.Event.tool_progress/3`. Hosts may use their own event types,
  such as `:subagent_progress`. Progress is transient presentation data: the
  call's `:tool_end` or `:tool_error` follows it.

  Does nothing when `context` has no event callback, as when a tool runs
  outside the loop. Returns `:ok`.
  """
  @spec progress(map(), Event.type(), map()) :: :ok
  def progress(context, type \\ :tool_progress, data)
      when is_map(context) and is_atom(type) and is_map(data) do
    case Map.get(context, :event_callback) do
      callback when is_function(callback, 1) ->
        callback.(progress_event(type, Map.get(context, :tool_call_id), data))
        :ok

      _other ->
        :ok
    end
  end

  defp progress_event(:tool_progress, tool_call_id, data),
    do: Event.tool_progress(tool_call_id, data)

  defp progress_event(type, tool_call_id, data),
    do: Event.new(type, Map.put(data, :tool_call_id, tool_call_id))
end

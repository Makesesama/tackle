defmodule Tackle.Lib.LLM do
  @moduledoc """
  Provider-agnostic LLM behaviour — the keystone seam of Tackle.Lib.

  Tackle.Lib never talks to a provider directly. The agent loop
  (`Tackle.Lib.Loop`) calls `generate/2` on the configured adapter module, and the
  host application supplies an adapter that fulfils this contract. This is what
  makes Tackle.Lib provider-agnostic: swap the adapter, keep the loop.

  ## Selecting an adapter and model

  Hosts that make multiple adapters available should give each adapter a stable
  `adapter_id/0` and a `models/0` list, then resolve a canonical model reference:

      {:ok, selection} =
        Tackle.Lib.LLM.select(
          [MyApp.AI.CodexAdapter, MyApp.AI.AnthropicAdapter],
          "openai-codex/gpt-5.5"
        )

      state = Tackle.Lib.new(llm: selection)

  The selection is stored on agent state and frozen in the per-turn snapshot.
  Its adapter-local model id is passed as `opts[:model]`, so separate states can
  use different providers without changing application-global configuration.

  For compatibility, callers may still configure one default adapter. Tackle.Lib
  reads its own `:tackle_lib` key first and also accepts the historical host key:

      config :tackle_lib, llm: MyApp.AI.TackleAdapter
      config :my_app, Tackle.Lib, llm: MyApp.AI.TackleAdapter

  `adapter/0`, `generate/2`, and `stream/3` use that default. Adapters may
  implement the optional `stream/3` callback; Tackle.Lib normalizes provider
  stream events into `%Tackle.Lib.Event{}` before hosts see them.

  ## The contract

  An adapter implements `generate/2`:

      @callback generate(schema :: keyword() | nil, opts :: keyword()) ::
                  {:ok, response()} | {:error, term()}

  * `schema` — an optional Tackle.Lib/`AI.Object`-style keyword schema describing a
    structured non-tool response (see `Tackle.Lib.SystemPrompt.response_schema/0`),
    or `nil` for a plain/native turn. Tool calls are delivered through
    provider-native `tool_calls`, not through this schema.
  * `opts` — passthrough options. Tackle.Lib sets `:model`, `:system`,
    `:messages`, `:temperature`, and `:strict_schema`, then appends any
    host-supplied `llm_opts` from the agent state.

  ### `opts[:messages]` — the structured message array (the contract)

  The conversation is delivered EXCLUSIVELY via `opts[:messages]`: a
  provider-neutral, role-tagged array (see `Tackle.Lib.Messages.to_provider/1`)
  where each conversation turn is its own map — `:user`, `:assistant` (with
  native `:tool_calls`), and `:tool` (linked by `:tool_call_id`). Adapters send
  THIS array to the provider, preserving turn structure and enabling provider
  prompt caching. The trailing per-turn instruction is the last `:user` entry
  of the array.

  When a run is cancellable, opts also
    include `:cancellation_signal`; adapters should observe it and abort
    provider work when possible. Adapters may honour or ignore extras.

  On success the adapter returns `{:ok, %{data: map, usage: map | Tackle.Lib.Usage.t() | nil, model: String.t() | nil}}`
  where `:data` contains assistant `content` and/or native `tool_calls`, or a
  parsed structured response for non-tool calls. Adapters may return opaque,
  non-secret `:provider_state` continuation metadata; Tackle.Lib stores it on
  the assistant message and returns it only to subsequent adapters, which must
  validate the originating provider and model before replaying it. `generate/3`
  normalizes provider-specific usage maps into `%Tackle.Lib.Usage{}` before returning so the
  loop and host persistence see one stable shape. Cost is optional because many
  providers return token counts only; pricing remains host-owned.
  """

  alias Tackle.Lib.Event
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.Usage

  @type usage :: Usage.t() | nil

  @type adapter_usage :: Usage.t() | map() | nil

  @type adapter_response :: %{
          required(:data) => map(),
          required(:usage) => adapter_usage(),
          required(:model) => String.t() | nil,
          optional(:provider) => String.t() | atom() | nil,
          optional(:provider_state) => map() | nil
        }

  @type response :: %{
          required(:data) => map(),
          required(:usage) => usage(),
          required(:model) => String.t() | nil,
          optional(:provider) => String.t() | atom() | nil,
          optional(:provider_state) => map() | nil
        }

  @doc "A stable lowercase identifier used as the model-reference prefix."
  @callback adapter_id() :: String.t()

  @doc "The adapter-local model identifiers available for explicit selection."
  @callback models() :: [String.t()]

  @callback generate(schema :: keyword() | nil, opts :: keyword()) ::
              {:ok, adapter_response()} | {:error, term()}

  @callback stream(
              schema :: keyword() | nil,
              opts :: keyword(),
              event_callback :: (term() -> any())
            ) :: {:ok, adapter_response()} | {:error, term()}

  @optional_callbacks adapter_id: 0, models: 0, stream: 3

  @doc """
  Selects an adapter and model from a canonical `adapter_id/model` reference.

  Adapter ids must be lowercase strings containing letters, digits, and hyphens.
  The model portion may itself contain `/`; only the first slash separates the
  adapter id. Every supplied adapter must export `generate/2`, `adapter_id/0`,
  and `models/0`, and adapter ids must be unique.
  """
  @spec select([module()], String.t()) :: {:ok, Selection.t()} | {:error, term()}
  defdelegate select(adapters, model_ref), to: Selection, as: :resolve

  @doc """
  Returns the configured default LLM adapter module.

  This compatibility API is used when state has no explicit selection. New
  multi-provider hosts should prefer `select/2` and pass the resulting selection
  to `Tackle.Lib.new/1`.

  Raises if no adapter is configured — Tackle.Lib is provider-agnostic by design and
  has no built-in default; the host app MUST supply one.
  """
  @spec adapter() :: module()
  def adapter do
    resolved =
      Application.get_env(:tackle_lib, :llm) ||
        get_in(Application.get_env(:my_app, Tackle.Lib, []), [:llm])

    case resolved do
      nil ->
        raise """
        No Tackle.Lib LLM adapter configured. Set one in config:

            config :tackle_lib, llm: MyApp.AI.TackleAdapter

        The adapter module must implement the Tackle.Lib.LLM behaviour.
        """

      module when is_atom(module) ->
        module
    end
  end

  @doc """
  Delegates to the configured adapter's `generate/2`.
  """
  @spec generate(keyword() | nil, keyword()) :: {:ok, response()} | {:error, term()}
  def generate(schema, opts \\ []) do
    generate_with(adapter(), schema, opts)
  end

  @doc """
  Delegates to a specific adapter's `generate/2`.

  This is used by per-turn snapshots so a turn can continue with the adapter
  that was resolved when the turn started, even if application config changes
  while the turn is running.
  """
  @spec generate_with(module() | nil, keyword() | nil, keyword()) ::
          {:ok, response()} | {:error, term()}
  def generate_with(adapter, schema, opts \\ [])

  def generate_with(adapter, schema, opts)
      when is_atom(adapter) and not is_nil(adapter) do
    with {:ok, response} <- adapter.generate(schema, opts) do
      {:ok, normalize_response(response)}
    end
  end

  def generate_with(nil, _schema, _opts) do
    {:error, :missing_llm_adapter}
  end

  @doc """
  Streams through the configured adapter when supported.

  The adapter may emit provider-specific chunks/events to the callback it
  receives. Tackle.Lib converts each one to `%Tackle.Lib.Event{}` before invoking the
  host callback. If the adapter does not implement `stream/3`, Tackle.Lib falls back
  to `generate/2` and emits a normalized usage event when usage exists.
  """
  @spec stream(keyword() | nil, keyword(), (Event.t() -> any())) ::
          {:ok, response()} | {:error, term()}
  def stream(schema, opts, event_callback) when is_function(event_callback, 1) do
    stream_with(adapter(), schema, opts, event_callback)
  end

  @doc """
  Streams through a specific adapter when supported.

  Mirrors `stream/3`, but uses the adapter supplied by a per-turn snapshot
  instead of resolving current application config.
  """
  @spec stream_with(module() | nil, keyword() | nil, keyword(), (Event.t() -> any())) ::
          {:ok, response()} | {:error, term()}
  def stream_with(adapter, schema, opts, event_callback)
      when is_atom(adapter) and not is_nil(adapter) and is_function(event_callback, 1) do
    if function_exported?(adapter, :stream, 3) do
      provider = Keyword.get(opts, :provider)

      adapter_callback = fn provider_event ->
        provider_event
        |> Event.normalize(provider: provider)
        |> event_callback.()
      end

      with {:ok, response} <- adapter.stream(schema, opts, adapter_callback) do
        {:ok, normalize_response(response)}
      end
    else
      with {:ok, response} <- generate_with(adapter, schema, opts) do
        emit_usage_event(response, event_callback)
        {:ok, response}
      end
    end
  end

  def stream_with(nil, _schema, _opts, _event_callback) do
    {:error, :missing_llm_adapter}
  end

  defp normalize_response(%{} = response) do
    model = Map.get(response, :model)
    provider = Map.get(response, :provider)
    usage = Usage.normalize(Map.get(response, :usage), model: model, provider: provider)

    Map.put(response, :usage, usage)
  end

  defp emit_usage_event(%{usage: nil}, _event_callback), do: :ok

  defp emit_usage_event(%{usage: usage}, event_callback) do
    usage
    |> Event.usage()
    |> event_callback.()
  end
end

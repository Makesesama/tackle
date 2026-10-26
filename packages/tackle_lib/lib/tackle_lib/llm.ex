defmodule Tackle.Lib.LLM do
  @moduledoc """
  Provider-agnostic LLM behaviour — the keystone seam of Tackle.Lib.

  Tackle.Lib never talks to a provider directly. The agent loop
  (`Tackle.Lib.Loop`) calls `generate_with/3` or `stream_with/4` with the
  state's selection, and the host application supplies an adapter that fulfils
  this contract. This is what makes Tackle.Lib provider-agnostic: swap the
  adapter, keep the loop.

  ## Selecting a provider and model

  Every call goes through a `Tackle.Lib.LLM.Selection`; there is no
  application-wide default adapter. Give each adapter a stable `adapter_id/0`
  and a `models/0` list, then resolve a canonical `provider_id/model`
  reference:

      {:ok, selection} =
        Tackle.Lib.LLM.select(
          [MyApp.AI.CodexAdapter, MyApp.AI.AnthropicAdapter],
          "openai-codex/gpt-5.5"
        )

      state = Tackle.Lib.new(llm: selection)

  A bare adapter module stands for its default providers (see
  `Tackle.Lib.LLM.Provider`), so its `adapter_id/0` is usually also a provider
  id. Hosts that configure several instances of one adapter pass
  `%Tackle.Lib.LLM.Provider{}` structs instead.

  The selection is stored on agent state, which a turn runs with unchanged.
  Its adapter-local model id is passed as `opts[:model]`, and the provider as
  `opts[:provider_id]` and `opts[:provider_settings]`, so separate states can
  use different providers without application-global configuration.

  ## The contract

  An adapter implements `generate/2`, `stream/3`, or both:

      @callback generate(schema :: map() | nil, opts :: keyword()) ::
                  {:ok, adapter_result()} | {:error, term()}

      @callback stream(schema :: map() | nil, opts :: keyword(), (term() -> any())) ::
                  {:ok, adapter_result()} | {:error, term()}

  An adapter that exports only `stream/3` is called with a callback that drops
  its events when the caller does not stream, and one that exports only
  `generate/2` is generated when the caller streams. `stream/3` emits
  provider-specific chunks or events to its callback; Tackle.Lib normalizes
  each into a `%Tackle.Lib.Event{}` before the caller sees it.

  * `schema` — `nil` for a chat turn, or a JSON Schema object describing a
    structured response. Callers may pass a Tackle.Lib keyword schema (see
    `Tackle.Lib.Tool.Schema`) or a JSON Schema map; the library converts it
    once, so adapters always receive a JSON Schema map with string keys
    (`Tackle.Lib.Tool.Schema.JsonSchema.to_json_schema/1`). Tool calls are
    delivered through provider-native `tool_calls`, not through this schema.
  * `opts` — the request options described below.

  ### Request options

  Callers build options with `request_opts/3`, so the keys that define a call
  cannot be replaced by host `llm_opts`. Adapters receive these standard keys:

  * `:model` — the adapter-local model id.
  * `:provider_id` and `:provider_settings` — the selected provider (see
    `Tackle.Lib.LLM.Provider`); adapters use the id as their credential
    namespace.
  * `:messages` — the conversation (see below).
  * `:system` — the system prompt, or absent.
  * `:tools` — tool definitions (`Tackle.Lib.Tool.definition/1`): maps with a
    `:name`, a `:description`, and a JSON Schema `:input_schema`. `[]` means
    no tools.
  * `:tool_choice` — `"none"` when a caller registers tools only for prompt
    cache identity (the compaction summarizer) or wants plain text; absent
    otherwise. Hosts cannot set it (see `request_opts/3`).
  * `:session_id` — a stable id adapters may use for prompt-cache affinity.
  * `:cancellation_signal` — a `Tackle.Lib.Cancellation` signal; adapters
    should observe it and abort provider work when possible.
  * `:temperature` — the sampling temperature. The agent loop defaults it to
    `0.3`; host options override it.
  * `:max_tokens` — the most output tokens to generate, or absent. An adapter
    whose provider refuses an output limit ignores it and documents that.
  * `:reasoning_effort` — the thinking level (see `Tackle.Lib.Thinking`) as a
    string or atom, `:none` for no reasoning, or absent for the model's
    default. Adapters read it with `Tackle.Lib.Thinking.parse/1` and accept
    every level, sending the nearest one the model supports.
  * `:receive_timeout` — milliseconds to wait for the provider, or absent.
  * `:credential_store` and `:interaction` — the host's
    `Tackle.Lib.CredentialStore` and `Tackle.Lib.Interaction` handles.

  Other host options pass through; adapters may honour or ignore them.

  ### `opts[:messages]` — the structured message array

  The conversation is delivered EXCLUSIVELY via `opts[:messages]`: a
  provider-neutral, role-tagged array (see `Tackle.Lib.Messages.to_provider/1`)
  where each conversation turn is its own map — `:user`, `:assistant` (with
  native `:tool_calls`), and `:tool` (linked by `:tool_call_id`). Adapters send
  THIS array to the provider, preserving turn structure and an append-only
  prefix for provider prompt caching.

  ### Results

  On success the adapter returns `{:ok, %{data: map, usage: map | nil, model:
  String.t() | nil}}`, optionally with opaque `:provider_state` and a
  `:stop_reason` (`t:Tackle.Lib.LLM.Response.stop_reason/0`). `:data` holds
  the assistant's `"content"`, `"thinking"`, and native `"tool_calls"`, or the
  parsed object of a structured response. `generate_with/3` and
  `stream_with/4` check the result and return `{:ok,
  %Tackle.Lib.LLM.Response{}}` (see `Tackle.Lib.LLM.Response.from_result/1`):

  * `content` and `thinking` must be strings or absent, and `tool_calls` a
    list of calls `Tackle.Lib.Tool.Call.normalize/1` accepts. A structured
    response keeps its parsed object in the response's `:data`; these three
    keys keep their chat meaning there, so a schema must not use them for
    anything else.
  * `usage` is canonical usage: a `%Tackle.Lib.Usage{}` the adapter built
    from its provider's report (usually with `Tackle.Lib.Usage.new/1`), or a
    map with the struct's field names. It is priced from the selection's model
    card when the provider reports no cost; derived cost estimates are marked,
    and hosts keep billing and persistence policy. The response's usage is the
    call's usage of record: `:usage` events a streaming adapter emits reach
    the caller normalized but unpriced (the agent loop drops them and reports
    the response's usage once).
  * `stop_reason` is `:end`, `:max_tokens`, `:tool_calls`, or
    `:content_filter` when the provider reports why it stopped, and absent
    otherwise. Callers that cap the output (the compaction summarizer) read
    `:max_tokens` as a cut-off answer.
  * `provider` is the selected provider id, whatever the adapter reported.
  * `provider_state` is stamped with the `"provider"` id and the requested
    `"model"`.

  A result that does not fit, an adapter return other than `{:ok, _}` or
  `{:error, _}`, and an adapter that raises, throws, or exits never crash the
  caller. A malformed result is `{:error, %Tackle.Lib.LLM.Error{kind:
  :invalid_response}}`, whose `details` hold the `:reason` and the result's
  `:usage` (the provider still spent the tokens); a crash is
  `{:error, %Tackle.Lib.LLM.Error{kind: :unknown}}`, which is not retried.

  ### Provider state

  Adapters may return opaque, non-secret `:provider_state` continuation
  metadata, such as reasoning to replay. Tackle.Lib stores it on the
  assistant message and passes it back as the message's `:provider_state`,
  but only to the provider and model that produced it: before calling an
  adapter, the library drops every message's provider state whose stamped
  `"provider"` and `"model"` differ from the call's. Adapters therefore read
  provider state without checking its origin, and check only what else it
  depends on (such as an auth mode).

  ## Errors

  Adapters return provider and transport failures as
  `{:error, %Tackle.Lib.LLM.Error{}}`: an HTTP error response, a failed
  connection, or an error reported inside a stream, classified by `kind`
  with the HTTP status and any `Retry-After` hint. The loop retries transient
  kinds under `Tackle.Lib.Retry`, compacts and asks again after a
  `:context_window_exceeded` error, and shows the error's message otherwise.
  Other failures, such as missing credentials or an unsupported model, stay
  plain reasons and are never retried.

  ## Account flows

  The behaviour also covers everything a provider needs beyond generation, so a
  frontend never hard-codes provider knowledge. Adapters may optionally
  implement `login/1`, `logout/1`, `status/1`, and `usage/1`. Interactive work
  talks to the user through a `Tackle.Lib.Interaction` handle passed in `opts`,
  and credential access goes through `Tackle.Lib.CredentialStore`, keeping the
  adapter independent of terminal rendering and host storage. Hosts pass the
  provider's `:provider_id` and `:provider_settings` to these callbacks too;
  adapters use the provider id as their credential namespace (see
  `Tackle.Lib.LLM.Provider.id/2`) so each provider keeps its own login.
  Adapters may expose optional model limits and price cards through
  `model_info/1`.
  """

  alias Tackle.Lib.Event
  alias Tackle.Lib.LLM.Error
  alias Tackle.Lib.LLM.Provider
  alias Tackle.Lib.LLM.Response
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.ModelInfo
  alias Tackle.Lib.Tool.Schema.JsonSchema
  alias Tackle.Lib.Usage

  @typedoc """
  A structured-response schema as callers pass it: a Tackle.Lib keyword
  schema, a JSON Schema map, or `nil` for a chat turn. Adapters always
  receive a JSON Schema map with string keys, or `nil`.
  """
  @type schema :: keyword() | map() | nil

  @typedoc "What an adapter's `generate/2` or `stream/3` returns on success."
  @type adapter_result :: %{
          required(:data) => map(),
          required(:usage) => Usage.t() | map() | nil,
          required(:model) => String.t() | nil,
          optional(:provider_state) => map() | nil
        }

  @typedoc "What `generate_with/3` and `stream_with/4` return."
  @type result :: {:ok, Response.t()} | {:error, term()}

  @doc """
  A stable lowercase identifier naming the adapter type.

  It is also the id of the adapter's default provider unless the adapter
  exports `default_providers/0`.
  """
  @callback adapter_id() :: String.t()

  @doc """
  The adapter's built-in providers as `{provider_id, settings}` tuples.

  Optional. Without it, a bare adapter module stands for one provider whose id
  is `adapter_id/0` with empty settings.
  """
  @callback default_providers() :: [{String.t(), Provider.settings()}]

  @doc "The adapter-local model identifiers available for explicit selection."
  @callback models() :: [String.t()]

  @doc "Like `models/0`, for one provider's settings. Preferred when exported."
  @callback models(settings :: Provider.settings()) :: [String.t()]

  @doc "Optional adapter-owned limits and price card for one adapter-local model."
  @callback model_info(model :: String.t()) :: ModelInfo.t() | map() | nil

  @doc "Like `model_info/1`, for one provider's settings. Preferred when exported."
  @callback model_info(model :: String.t(), settings :: Provider.settings()) ::
              ModelInfo.t() | map() | nil

  @doc """
  Generates one response. Optional when the adapter exports `stream/3`.

  `schema` is `nil` or a JSON Schema map with string keys; see the module docs
  for the options and the result.
  """
  @callback generate(schema :: map() | nil, opts :: keyword()) ::
              {:ok, adapter_result()} | {:error, term()}

  @doc """
  Streams one response, emitting provider events to `event_callback`.
  Optional when the adapter exports `generate/2`.
  """
  @callback stream(
              schema :: map() | nil,
              opts :: keyword(),
              event_callback :: (term() -> any())
            ) :: {:ok, adapter_result()} | {:error, term()}

  @doc """
  Runs the adapter's interactive login flow and returns credentials to store.

  The adapter owns the complete flow—device codes, browser hand-off, API-key
  prompts—and talks to the user through the `:interaction` handle in `opts`
  (see `Tackle.Lib.Interaction`). The returned map is opaque and JSON-compatible;
  the host persists it under the provider's id (`opts[:provider_id]`) and
  replays it to the adapter through a `:credential_store` handle.

  This callback is optional. Adapters whose credentials are supplied externally
  (environment variables, injected configuration) simply omit it, and hosts
  report `:unsupported_provider_flow`.
  """
  @callback login(opts :: keyword()) :: {:ok, credentials :: map()} | {:error, term()}

  @doc """
  Removes or revokes the adapter's stored credentials.

  Optional. When an adapter omits `logout/1`, the host deletes the credentials
  stored under the provider id. Adapters that must call a provider revocation
  endpoint implement it and are then responsible for their own cleanup.
  """
  @callback logout(opts :: keyword()) :: :ok | {:error, term()}

  @doc """
  Reports the adapter's stored credential state.

  Optional. When an adapter omits `status/1`, the host reads the credential
  store and reports `:stored` or `:missing`. Adapters that can detect expiry or
  account state should return their own atom or `{:ok, details}`.
  """
  @callback status(opts :: keyword()) :: {:ok, status :: term()} | {:error, term()}

  @doc """
  Returns the adapter's provider account usage.

  Optional. The report is a host-renderable, JSON-compatible map (for example a
  plan name, credit balance, or rate-limit windows). Tackle.Lib never interprets
  it; the frontend decides how to present it. Adapters that expose no account
  endpoint omit it and hosts report `:unsupported_provider_flow`.
  """
  @callback usage(opts :: keyword()) :: {:ok, report :: map()} | {:error, term()}

  @optional_callbacks adapter_id: 0,
                      default_providers: 0,
                      models: 0,
                      models: 1,
                      model_info: 1,
                      model_info: 2,
                      generate: 2,
                      stream: 3,
                      login: 1,
                      logout: 1,
                      status: 1,
                      usage: 1

  @doc """
  Selects a provider and model from a canonical `provider_id/model` reference.

  `sources` are `Tackle.Lib.LLM.Provider` structs or adapter modules, which
  stand for their default providers. Provider ids must be lowercase strings
  containing letters, digits, and hyphens, and must be unique. The model
  portion may itself contain `/`; only the first slash separates the provider
  id. Every adapter must export `generate/2` or `stream/3`, `adapter_id/0`, and
  `models/1` or `models/0`.
  """
  @spec select([Provider.source()], String.t()) :: {:ok, Selection.t()} | {:error, term()}
  defdelegate select(adapters, model_ref), to: Selection, as: :resolve

  @doc """
  Returns true when `reason` is a provider-confirmed context-window overflow.

  Adapters report one as a `Tackle.Lib.LLM.Error` of kind
  `:context_window_exceeded` (see `Tackle.Lib.LLM.Error.from_response/3` and
  `Tackle.Lib.LLM.Error.from_stream/1`), and the agent loop then compacts and
  asks again. Every other reason is not an overflow.
  """
  @spec context_window_exceeded?(term()) :: boolean()
  def context_window_exceeded?(%Error{kind: :context_window_exceeded}), do: true
  def context_window_exceeded?(_reason), do: false

  # Host options that would force a tool choice, restrict or weight the
  # registered tools, or let the provider schedule tool calls. The loop owns
  # the tool list and the execution order (see `Tackle.Lib.Tool.Policy`).
  @tool_selection_opts [
    :tool_choice,
    :parallel_tool_calls,
    :allowed_tools,
    :disallowed_tools,
    :tool_weights,
    :tool_policy
  ]

  @doc """
  Builds adapter options from a request, overridable defaults, and host options.

  `request` holds the options that define the call (such as `:model`,
  `:messages`, `:system`, and `:tools`); host options never replace them.
  `defaults` (such as `:temperature`) are tuning values that host options do
  override. Host options are otherwise passed through, except the
  tool-selection options Tackle.Lib does not support, which are dropped:
  `:tool_choice`, `:parallel_tool_calls`, `:allowed_tools`,
  `:disallowed_tools`, `:tool_weights`, and `:tool_policy`. A request may
  still set one itself (the compaction summarizer sends `tool_choice:
  "none"`). The result has one entry per key, so adapters read the same value
  whether they use `Keyword.get/2` or `Map.new/1`.
  """
  @spec request_opts(keyword(), keyword(), keyword()) :: keyword()
  def request_opts(request, defaults, host_opts)
      when is_list(request) and is_list(defaults) and is_list(host_opts) do
    host_opts = Keyword.drop(host_opts, Keyword.keys(request) ++ @tool_selection_opts)
    request ++ Keyword.merge(defaults, host_opts)
  end

  @doc """
  Safely resolves and validates optional metadata for one adapter-local model.

  Accepts an adapter module or a provider. Adapters exporting `model_info/2`
  get the provider's settings, or empty settings for a bare module (which
  stands for a provider with empty settings), and others `model_info/1`.
  Adapters without `model_info` return `{:ok, nil}`.
  Callback failures and malformed metadata are returned explicitly so hosts
  never run with silently invalid model limits or prices.
  """
  @spec model_info(module() | Provider.t(), String.t()) ::
          {:ok, ModelInfo.t() | nil} | {:error, term()}
  def model_info(%Provider{adapter: adapter, settings: settings}, model)
      when is_binary(model) and model != "",
      do: adapter_model_info(adapter, model, settings)

  def model_info(adapter, model)
      when is_atom(adapter) and not is_nil(adapter) and is_binary(model) and model != "",
      do: adapter_model_info(adapter, model, %{})

  def model_info(adapter, model), do: {:error, {:invalid_model_info_request, adapter, model}}

  @doc """
  Generates one response through a selection.

  The selection passes its adapter-local model, provider id, and provider
  settings as `opts[:model]`, `opts[:provider_id]`, and
  `opts[:provider_settings]`, replacing any given. The agent loop calls it
  with the state's selection and no schema.

  Adapters that export only `stream/3` are streamed with a callback that
  drops their events. The result is described in the module docs: a
  `Tackle.Lib.LLM.Response` or `{:error, reason}`, never an exception.
  """
  @spec generate_with(Selection.t(), schema(), keyword()) :: result()
  def generate_with(%Selection{} = selection, schema, opts \\ []) when is_list(opts) do
    with {:ok, call} <- prepare(selection, schema, opts) do
      call
      |> invoke(nil)
      |> to_response(call)
    end
  end

  @doc """
  Streams one response through a selection.

  Mirrors `generate_with/3`. The adapter emits provider-specific chunks or
  events to the callback it receives; each is converted to a
  `%Tackle.Lib.Event{}` before `event_callback` sees it. An adapter that
  exports only `generate/2` is generated instead, and its response's usage is
  emitted as one `:usage` event.
  """
  @spec stream_with(Selection.t(), schema(), keyword(), (Event.t() -> any())) :: result()
  def stream_with(%Selection{} = selection, schema, opts, event_callback)
      when is_list(opts) and is_function(event_callback, 1) do
    with {:ok, call} <- prepare(selection, schema, opts) do
      if function_exported?(call.adapter, :stream, 3) do
        call
        |> invoke(stream_callback(call, event_callback))
        |> to_response(call)
      else
        with {:ok, response} <- call |> invoke(nil) |> to_response(call) do
          if response.usage, do: event_callback.(Event.usage(response.usage))
          {:ok, response}
        end
      end
    end
  end

  # One adapter call: the adapter, its options, and what the boundary needs to
  # check and stamp the result.
  defp prepare(%Selection{adapter: adapter} = selection, schema, opts) do
    %Selection{provider_id: provider_id, model: model} = selection

    opts =
      opts
      |> Keyword.put(:model, model)
      |> Keyword.put(:provider_id, provider_id)
      |> Keyword.put(:provider_settings, selection.provider_settings)

    with :ok <- Provider.ensure_loaded(adapter),
         :ok <- Provider.ensure_generates(adapter),
         {:ok, schema} <- json_schema(schema) do
      {:ok,
       %{
         adapter: adapter,
         info: selection.model_info,
         provider_id: provider_id,
         model: model,
         schema: schema,
         opts: drop_foreign_provider_state(opts, provider_id, model)
       }}
    end
  end

  # Adapters receive one JSON Schema form: a keyword schema is projected once
  # here, and a map schema gets string keys.
  defp json_schema(nil), do: {:ok, nil}

  defp json_schema(schema) when is_list(schema) do
    if Keyword.keyword?(schema),
      do: {:ok, JsonSchema.to_json_schema(schema)},
      else: {:error, {:invalid_response_schema, schema}}
  rescue
    exception in ArgumentError ->
      {:error, {:invalid_response_schema, Exception.message(exception)}}
  end

  defp json_schema(%{} = schema) when not is_struct(schema), do: {:ok, stringify_keys(schema)}
  defp json_schema(schema), do: {:error, {:invalid_response_schema, schema}}

  defp stringify_keys(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  # Provider state is replayed only to the provider and model that produced
  # it, as stamped by `to_response/2`; anything else is dropped from the
  # messages before the adapter sees them.
  defp drop_foreign_provider_state(opts, provider_id, model) do
    case Keyword.fetch(opts, :messages) do
      {:ok, messages} when is_list(messages) ->
        Keyword.put(opts, :messages, Enum.map(messages, &replayable(&1, provider_id, model)))

      _other ->
        opts
    end
  end

  defp replayable(%{} = message, provider_id, model) when not is_struct(message) do
    Enum.reduce([:provider_state, "provider_state"], message, fn key, message ->
      case Map.fetch(message, key) do
        {:ok, state} ->
          if own_state?(state, provider_id, model), do: message, else: Map.delete(message, key)

        :error ->
          message
      end
    end)
  end

  defp replayable(message, _provider_id, _model), do: message

  defp own_state?(%{"provider" => provider, "model" => model}, provider, model)
       when is_binary(provider) and is_binary(model),
       do: true

  defp own_state?(_state, _provider_id, _model), do: false

  defp stream_callback(call, event_callback) do
    fn provider_event ->
      provider_event
      |> Event.normalize(provider: call.provider_id)
      |> event_callback.()
    end
  end

  # Calls the adapter. Anything other than `{:ok, result}` or
  # `{:error, reason}`, and any exception, throw, or exit, becomes an error.
  defp invoke(call, event_callback) do
    result =
      cond do
        event_callback ->
          call.adapter.stream(call.schema, call.opts, event_callback)

        function_exported?(call.adapter, :generate, 2) ->
          call.adapter.generate(call.schema, call.opts)

        true ->
          call.adapter.stream(call.schema, call.opts, fn _event -> :ok end)
      end

    case result do
      {:ok, _result} -> result
      {:error, _reason} -> result
      other -> {:invalid, {:result, other}}
    end
  rescue
    exception -> {:error, adapter_failure(call.adapter, :error, exception, __STACKTRACE__)}
  catch
    kind, reason -> {:error, adapter_failure(call.adapter, kind, reason, __STACKTRACE__)}
  end

  defp adapter_failure(adapter, kind, reason, stacktrace) do
    Error.new(:unknown,
      message: "The LLM adapter #{inspect(adapter)} failed: #{failure_text(kind, reason)}",
      details: %{adapter: adapter, kind: kind, reason: reason, stacktrace: stacktrace}
    )
  end

  defp failure_text(:error, exception), do: Exception.message(exception)

  defp failure_text(kind, reason),
    do: "#{kind} #{inspect(reason, limit: 10, printable_limit: 200)}"

  defp to_response({:ok, result}, call) do
    case Response.from_result(result) do
      {:ok, response} ->
        provider = call.provider_id

        {:ok,
         %{
           response
           | provider: provider,
             usage: price(response.usage, call, response.model, provider),
             provider_state: stamp_state(response.provider_state, provider, call.model)
         }}

      {:error, {:invalid_response, detail}} ->
        {:error, invalid_response(detail, result, call)}
    end
  end

  defp to_response({:invalid, detail}, call), do: {:error, invalid_response(detail, nil, call)}
  defp to_response({:error, reason}, _call), do: {:error, reason}

  defp stamp_state(%{} = state, provider, model),
    do: Map.merge(state, %{"provider" => provider, "model" => model})

  defp stamp_state(nil, _provider, _model), do: nil

  # A malformed result is an `:invalid_response` error. Its usage, when the
  # result has a usable one, is kept in the details: the provider still
  # spent the tokens.
  defp invalid_response(detail, result, call) do
    provider = call.provider_id

    usage =
      case result_field(result, :usage) do
        %Usage{} = usage -> price(usage, call, result_field(result, :model), provider)
        %{} = usage -> price(Usage.normalize(usage), call, result_field(result, :model), provider)
        _invalid -> nil
      end

    Error.new(:invalid_response,
      message: invalid_response_message(detail),
      details: %{reason: detail, usage: usage}
    )
  end

  defp result_field(%{} = result, key) when not is_struct(result), do: Map.get(result, key)
  defp result_field(_result, _key), do: nil

  defp invalid_response_message({:tool_calls, reason}),
    do: "Invalid provider tool calls: #{inspect(reason)}"

  defp invalid_response_message(detail), do: "Invalid provider response: #{inspect(detail)}"

  defp price(nil, _call, _model, _provider), do: nil

  defp price(%Usage{} = usage, call, model, provider) do
    usage
    |> Usage.normalize(model: model || call.model, provider: provider)
    |> then(&estimate_cost(call.info, &1))
  end

  defp estimate_cost(nil, usage), do: usage
  defp estimate_cost(%ModelInfo{} = info, usage), do: ModelInfo.estimate_cost(info, usage)

  defp adapter_model_info(adapter, model, settings) do
    with {:ok, value} <- Provider.model_info(adapter, settings, model) do
      ModelInfo.normalize(model, value)
    end
  end
end

defmodule Tackle.Web.Models do
  @moduledoc """
  Database-backed providers and review defaults, owned by users
  (docs/TACKLE_WEB_PLAN.md §7.12). Only the bundled OpenRouter and Codex
  adapters can be selected. Settings are revalidated against the owner's
  enabled providers both when saved and when resolved for a run.
  """

  use Ash.Domain, otp_app: :tackle_web, extensions: [AshAdmin.Domain]

  alias Tackle.Lib.LLM.Provider, as: LLMProvider
  alias Tackle.Review.Settings
  alias Tackle.Web.Models.{Provider, ReviewDefaults}

  admin do
    show? true
  end

  resources do
    resource Provider
    resource ReviewDefaults
  end

  # Authorise when an actor is given; see Tackle.Web.Accounts.
  authorization do
    authorize :when_requested
  end

  @typedoc "The id of the user whose providers and defaults are used."
  @type owner_id :: Ecto.UUID.t()

  @doc """
  Builds provider instances from the owner's enabled rows, without loading
  secrets. A nil owner (an installation without one) has no providers.
  """
  @spec enabled_providers(owner_id() | nil) :: {:ok, [LLMProvider.t()]} | {:error, term()}
  def enabled_providers(nil), do: {:ok, []}

  def enabled_providers(owner_id) do
    require Ash.Query

    with {:ok, rows} <-
           Provider
           |> Ash.Query.filter(owner_id == ^owner_id and enabled == true)
           |> Ash.Query.sort(:name)
           |> Ash.read() do
      providers =
        Enum.map(rows, fn row ->
          {:ok, provider} = LLMProvider.new(row.name, adapter(row.adapter), row.settings)
          provider
        end)

      {:ok, providers}
    end
  end

  @doc "The fixed adapter allowlist; never converts user input into module names."
  @spec adapter(:openrouter | :codex) :: module()
  def adapter(:openrouter), do: Tackle.Plugins.OpenRouter
  def adapter(:codex), do: Tackle.Plugins.Codex

  @doc """
  Validates repository/default JSON settings against the owner's providers
  enabled now. Profile is separate.
  """
  @spec validate_settings(owner_id() | nil, term()) :: {:ok, Settings.t()} | {:error, term()}
  def validate_settings(owner_id, json) do
    with {:ok, opts} <- settings_options(json),
         {:ok, providers} <- enabled_providers(owner_id) do
      Settings.new(opts, providers)
    end
  end

  @doc """
  Resolves repository JSON over the owner's defaults, per stage, then checks
  required detector/verifier models against the owner's enabled providers.
  Returns ready-to-run review settings. The request/repository's separately
  resolved profile is passed explicitly. A scorer model is optional (the
  review inherits the requester's model).
  """
  @spec resolve_settings(owner_id(), map(), atom()) :: {:ok, Settings.t()} | {:error, term()}
  def resolve_settings(owner_id, repository_settings \\ %{}, profile \\ :default) do
    with {:ok, opts} <- settings_options(repository_settings),
         {:ok, providers} <- enabled_providers(owner_id),
         {:ok, defaults} <- ReviewDefaults.get(owner_id),
         opts = merge_defaults(opts, defaults),
         :ok <- required_models(Keyword.fetch!(opts, :models)) do
      Settings.new(Keyword.put(opts, :profile, profile), providers)
    end
  end

  defp merge_defaults(opts, defaults) do
    Enum.reduce([:models, :thinking], opts, fn key, acc ->
      base = if defaults, do: Map.fetch!(defaults, key), else: %{}
      # Only known stage names become atoms; from_json validates the shape.
      base =
        Map.new(base, fn {stage, value} ->
          {Enum.find(Settings.stages(), &(Atom.to_string(&1) == stage)), value}
        end)

      Keyword.put(acc, key, Map.merge(base, Keyword.get(opts, key, %{})))
    end)
  end

  defp required_models(models) do
    missing = Enum.reject([:detector, :verifier], &Map.has_key?(models, &1))
    if missing == [], do: :ok, else: {:error, {:missing_review_models, missing}}
  end

  defp settings_options(%{"profile" => _profile}), do: {:error, :profile_must_be_separate}

  defp settings_options(json) do
    case Settings.from_json(json) do
      {:ok, opts} -> {:ok, opts}
      :error -> {:error, :invalid_review_settings_json}
    end
  end

  @doc false
  @spec json_value?(term()) :: boolean()
  def json_value?(%_{}), do: false

  def json_value?(value) when is_map(value),
    do:
      Enum.all?(value, fn {key, item} ->
        is_binary(key) and String.valid?(key) and json_value?(item)
      end)

  def json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)

  def json_value?(value) when is_binary(value), do: String.valid?(value)
  def json_value?(value) when is_number(value) or is_boolean(value) or is_nil(value), do: true

  def json_value?(_value), do: false
end

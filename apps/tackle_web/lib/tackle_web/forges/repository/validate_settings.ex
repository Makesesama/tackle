defmodule Tackle.Web.Forges.Repository.ValidateSettings do
  @moduledoc """
  Validates a repository's `settings`: the JSON form of
  `Tackle.Review.Settings` with string keys (`Settings.from_json/1`),
  without `profile` (the repository's `profile` attribute is the only place
  for it), and accepted by `Settings.new/2` against enabled providers.

  Models are also rechecked when a review runs, since providers can change.
  """

  use Ash.Resource.Validation

  alias Tackle.Review.Settings
  alias Tackle.Web.Models

  @impl Ash.Resource.Validation
  def validate(changeset, _opts, _context) do
    case check(Ash.Changeset.get_attribute(changeset, :settings)) do
      :ok -> :ok
      {:error, message} -> {:error, field: :settings, message: message}
    end
  end

  @impl Ash.Resource.Validation
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)

  @doc "Checks a settings map; see the module documentation."
  @spec check(term()) :: :ok | {:error, String.t()}
  def check(settings) when is_map(settings) do
    with :ok <- no_profile(settings),
         {:ok, opts} <- from_json(settings),
         {:ok, providers} <- Models.enabled_providers(),
         {:ok, _settings} <- Settings.new(opts, providers) do
      :ok
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "invalid review settings: #{inspect(reason)}"}
    end
  end

  def check(_settings), do: {:error, "must be a JSON object"}

  defp no_profile(settings) do
    if Map.has_key?(settings, "profile"),
      do: {:error, "set the profile with the repository's profile, not in its settings"},
      else: :ok
  end

  defp from_json(settings) do
    case Settings.from_json(settings) do
      {:ok, opts} ->
        {:ok, opts}

      :error ->
        {:error,
         "is not valid review settings: allowed are thinking, models, and max_steps " <>
           "objects keyed by stage, and a default_rules list, with valid values"}
    end
  end
end

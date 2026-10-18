defmodule Tackle.Hub.Models.ValidateProvider do
  @moduledoc false
  use Ash.Resource.Validation

  alias Tackle.Hub.Models
  alias Tackle.Lib.LLM.Provider

  @impl true
  def validate(changeset, _opts, _context) do
    name = Ash.Changeset.get_attribute(changeset, :name)
    settings = Ash.Changeset.get_attribute(changeset, :settings)
    credentials = Ash.Changeset.get_argument(changeset, :credentials)

    cond do
      not Provider.valid_id?(name) ->
        {:error, field: :name, message: "must be lowercase letters, digits and inner hyphens"}

      not Models.json_value?(settings) ->
        {:error, field: :settings, message: "must contain only JSON values with string keys"}

      Ash.Changeset.fetch_argument(changeset, :credentials) != :error and
          not Models.json_value?(credentials) ->
        {:error, field: :credentials, message: "must contain only JSON values with string keys"}

      true ->
        :ok
    end
  end
end

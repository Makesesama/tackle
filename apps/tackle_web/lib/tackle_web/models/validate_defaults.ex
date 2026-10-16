defmodule Tackle.Web.Models.ValidateDefaults do
  @moduledoc false
  use Ash.Resource.Validation

  alias Tackle.Web.Models

  @impl true
  def validate(changeset, _opts, _context) do
    json = %{
      "models" => Ash.Changeset.get_attribute(changeset, :models),
      "thinking" => Ash.Changeset.get_attribute(changeset, :thinking)
    }

    case Models.validate_settings(json) do
      {:ok, _settings} ->
        :ok

      {:error, reason} ->
        {:error, field: :models, message: "invalid defaults: #{inspect(reason)}"}
    end
  end
end

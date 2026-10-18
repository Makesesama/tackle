defmodule Tackle.Hub.ReviewJob.Failed do
  @moduledoc false
  use Ash.Resource.ManualUpdate

  alias Tackle.Hub.ReviewJob.Store
  alias Tackle.Hub.Reviews.ReviewRequest

  @impl true
  def update(changeset, _opts, _context) do
    case get_in(changeset.context, [:ash_oban, :job]) do
      %Oban.Job{} = job ->
        with {:ok, _recorded} <-
               Store.failed(
                 changeset.data.id,
                 job,
                 changeset.data.error || "review attempt failed"
               ) do
          Ash.get(ReviewRequest, changeset.data.id)
        end

      _missing ->
        {:error, "review jobs require an Oban attempt"}
    end
  end
end

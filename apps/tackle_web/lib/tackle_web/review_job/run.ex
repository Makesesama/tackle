defmodule Tackle.Web.ReviewJob.Run do
  @moduledoc false
  use Ash.Resource.ManualUpdate

  alias Tackle.Web.ReviewJob
  alias Tackle.Web.Reviews.ReviewRequest

  @impl true
  def update(changeset, _opts, _context) do
    with %Oban.Job{} = job <- get_in(changeset.context, [:ash_oban, :job]),
         :ok <- ReviewJob.run(%{request_id: changeset.data.id, job: job}) do
      Ash.get(ReviewRequest, changeset.data.id)
    else
      nil -> {:error, "review jobs require an Oban attempt"}
      {:error, reason} -> {:error, reason}
    end
  end
end

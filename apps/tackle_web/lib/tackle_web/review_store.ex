defmodule Tackle.Web.ReviewStore do
  @moduledoc """
  Durable, shared review state: comments and viewed markers per review.

  Review state belongs to a review inside a project, not to a browser tab, so it
  lives in one process that every review screen reads from and writes to.
  Mutations are broadcast on a per-review topic so a second viewer sees a comment
  appear without reloading.

  Durability is a JSON file per review under `Tackle.Web.Paths.reviews_root/0`, named
  after the project's slug and the review id.
  A write goes to a temporary file and is renamed into place, so an interrupted
  write cannot truncate a file that is already there. Writes happen on the
  GenServer, which is also what makes them serialized.
  """

  use GenServer

  require Logger

  alias Tackle.Web.Paths
  alias Tackle.Web.Review

  @topic_prefix "review:"

  @type key :: String.t()

  # -- client ---------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the review state of one review."
  @spec get(String.t(), String.t()) :: Review.t()
  def get(slug, review_id) do
    GenServer.call(__MODULE__, {:get, Review.file_name(slug, review_id)})
  end

  @doc """
  Adds a comment anchored to a line.

  Returns the stored comment so the caller can broadcast or scroll to it.
  """
  @spec add_comment(String.t(), String.t(), map()) ::
          {:ok, Review.comment()} | {:error, String.t()}
  def add_comment(slug, review_id, attrs) do
    GenServer.call(__MODULE__, {:add_comment, Review.file_name(slug, review_id), attrs})
  end

  @doc "Removes a comment by id. Unknown ids are ignored."
  @spec delete_comment(String.t(), String.t(), String.t()) :: :ok
  def delete_comment(slug, review_id, id) do
    GenServer.call(__MODULE__, {:delete_comment, Review.file_name(slug, review_id), id})
  end

  @doc "Marks a file as seen, or unseen."
  @spec set_viewed(String.t(), String.t(), String.t(), boolean()) :: :ok
  def set_viewed(slug, review_id, path, viewed?) do
    GenServer.call(
      __MODULE__,
      {:set_viewed, Review.file_name(slug, review_id), path, viewed? == true}
    )
  end

  @doc "Flips a file's viewed marker and returns its new value."
  @spec toggle_viewed(String.t(), String.t(), String.t()) :: boolean()
  def toggle_viewed(slug, review_id, path) do
    GenServer.call(__MODULE__, {:toggle_viewed, Review.file_name(slug, review_id), path})
  end

  @doc "Subscribes the calling process to this review's changes."
  @spec subscribe(String.t(), String.t()) :: :ok
  def subscribe(slug, review_id) do
    Phoenix.PubSub.subscribe(pubsub(), topic(slug, review_id))
  end

  @doc "PubSub topic on which review changes for one review are announced."
  @spec topic(String.t(), String.t()) :: String.t()
  def topic(slug, review_id) do
    @topic_prefix <> Review.file_name(slug, review_id)
  end

  # -- server ---------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{reviews: %{}}}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    {review, state} = fetch(key, state)
    {:reply, review, state}
  end

  @impl true
  def handle_call({:add_comment, key, attrs}, _from, state) do
    {review, state} = fetch(key, state)

    case build_comment(attrs) do
      {:ok, comment} ->
        review = %{review | comments: review.comments ++ [comment]}
        state = store(key, review, state)
        broadcast(key)
        {:reply, {:ok, comment}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:delete_comment, key, id}, _from, state) do
    {review, state} = fetch(key, state)
    review = %{review | comments: Enum.reject(review.comments, &(&1.id == id))}
    state = store(key, review, state)
    broadcast(key)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_viewed, key, path, viewed?}, _from, state) do
    {review, state} = fetch(key, state)
    review = %{review | viewed: put_viewed(review.viewed, path, viewed?)}
    state = store(key, review, state)
    broadcast(key)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:toggle_viewed, key, path}, _from, state) do
    {review, state} = fetch(key, state)
    viewed? = not MapSet.member?(review.viewed, path)
    review = %{review | viewed: put_viewed(review.viewed, path, viewed?)}
    state = store(key, review, state)
    broadcast(key)
    {:reply, viewed?, state}
  end

  # -- persistence ----------------------------------------------------------

  # The cache is authoritative once loaded, so a review is read from disk at
  # most once per server lifetime.
  defp fetch(key, state) do
    case Map.fetch(state.reviews, key) do
      {:ok, review} ->
        {review, state}

      :error ->
        review = load(key)
        {review, put_in(state.reviews[key], review)}
    end
  end

  defp load(key) do
    path = Path.join(Paths.reviews_root(), key)

    case File.read(path) do
      {:ok, contents} ->
        case JSON.decode(contents) do
          {:ok, stored} -> Review.from_json(stored)
          {:error, _reason} -> unreadable(path, "is not valid JSON")
        end

      {:error, :enoent} ->
        Review.new()

      {:error, reason} ->
        unreadable(path, :file.format_error(reason))
    end
  end

  defp unreadable(path, reason) do
    Logger.warning("Ignoring unreadable review state at #{path}: #{reason}")
    Review.new()
  end

  defp store(key, review, state) do
    persist(key, review)
    put_in(state.reviews[key], review)
  end

  defp persist(key, review) do
    dir = Paths.ensure_dir!(Paths.reviews_root())
    path = Path.join(dir, key)
    temporary = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(temporary, JSON.encode!(Review.to_json(review))),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        Logger.error("Could not persist review state to #{path}: #{:file.format_error(reason)}")
        :ok
    end
  end

  # -- helpers --------------------------------------------------------------

  defp put_viewed(viewed, path, true), do: MapSet.put(viewed, path)
  defp put_viewed(viewed, path, false), do: MapSet.delete(viewed, path)

  defp build_comment(attrs) do
    body = attrs |> Map.get("body", "") |> to_string() |> String.trim()
    path = attrs |> Map.get("path", "") |> to_string()

    with {:ok, side} <- parse_side(Map.get(attrs, "side")),
         {:ok, line} <- parse_line(Map.get(attrs, "line")),
         :ok <- validate_body(body),
         :ok <- validate_path(path) do
      {:ok,
       %{
         id: new_id(),
         path: path,
         side: side,
         line: line,
         body: body,
         author: attrs |> Map.get("author", "reviewer") |> to_string() |> String.trim(),
         inserted_at: DateTime.utc_now()
       }}
    end
  end

  defp parse_side(:new), do: {:ok, :new}
  defp parse_side(:old), do: {:ok, :old}
  defp parse_side("new"), do: {:ok, :new}
  defp parse_side("old"), do: {:ok, :old}
  defp parse_side(_other), do: {:error, "A comment has to be on the new or the old side."}

  defp parse_line(line) when is_integer(line) and line > 0, do: {:ok, line}

  defp parse_line(line) when is_binary(line) do
    case Integer.parse(line) do
      {number, ""} when number > 0 -> {:ok, number}
      _invalid -> {:error, "A comment needs a valid line number."}
    end
  end

  defp parse_line(_other), do: {:error, "A comment needs a valid line number."}

  defp validate_body(""), do: {:error, "Write something before saving the comment."}
  defp validate_body(_body), do: :ok

  defp validate_path(""), do: {:error, "A comment needs a file."}
  defp validate_path(_path), do: :ok

  defp new_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp broadcast(key) do
    Phoenix.PubSub.broadcast(pubsub(), @topic_prefix <> key, {:review_updated, key})
  end

  defp pubsub do
    Application.get_env(:tackle_web, :pubsub_server, Tackle.Web.PubSub)
  end
end

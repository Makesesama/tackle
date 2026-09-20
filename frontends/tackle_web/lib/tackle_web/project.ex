defmodule Tackle.Web.Project do
  @moduledoc """
  A place the assistant works: one local git repository or one GitHub
  repository.

  A project is the unit everything else hangs off. A chat runs in a project's
  working tree, and a review is a diff inside a project, so both are addressed
  by the project's `slug` in the URL and by `{slug, review_id}` in storage.

    * `kind` says which source module implements the project — see
      `Tackle.Web.Project.Source`.
    * `locator` is that source's own address: an absolute path for `:local`, an
      `owner/name` for `:github`. It is a plain string so the core never grows a
      field that only one source understands.
    * `name` is what the UI shows. It is derived when the project is created and
      is not part of the project's identity.

  ## Slugs

  The slug is derived from `kind` and `locator` and never changes for a given
  pair, so a URL, a review file and a transcript all agree on it, and re-adding
  the same locator eventually finds the same state. The readable part makes the
  URL legible; the short digest of the locator makes it unique, because
  slugifying alone would fold `/srv/a-b` and `/srv/a/b` onto the same string.
  """

  alias Tackle.Web.Project.Source.GitHub
  alias Tackle.Web.Project.Source.Local

  @type kind :: :local | :github

  @type t :: %__MODULE__{
          slug: String.t(),
          name: String.t() | nil,
          kind: kind(),
          locator: String.t(),
          default_branch: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @enforce_keys [:slug, :kind, :locator]
  defstruct [:slug, :name, :kind, :locator, :default_branch, :inserted_at]

  @sources %{local: Local, github: GitHub}

  # Readable part of a slug, before the digest. Long enough to name a
  # repository, short enough to keep a URL comfortable.
  @slug_words 40
  @digest_bytes 3

  @doc """
  The source module implementing a project or a kind.
  """
  @spec source(t() | kind()) :: module()
  def source(%__MODULE__{kind: kind}), do: source(kind)
  def source(kind) when is_atom(kind), do: Map.fetch!(@sources, kind)

  @doc "The kinds a project can be added as."
  @spec kinds() :: [kind()]
  def kinds, do: [:local, :github]

  @doc "A kind's name as the UI writes it."
  @spec label(kind()) :: String.t()
  def label(:local), do: "Local"
  def label(:github), do: "GitHub"

  @doc """
  The slug of a project that will be created for `kind` and `locator`.
  """
  @spec slug(kind(), String.t()) :: String.t()
  def slug(kind, locator) when is_atom(kind) and is_binary(locator) do
    "#{kind}-#{readable(locator)}-#{digest(locator)}"
  end

  @doc "Whether `value` names a kind."
  @spec kind(term()) :: {:ok, kind()} | :error
  def kind(value) when is_atom(value) do
    if Map.has_key?(@sources, value), do: {:ok, value}, else: :error
  end

  def kind(value) when is_binary(value), do: kind(safe_existing_atom(value))
  def kind(_value), do: :error

  @doc """
  The review id of the diff between two refs.

  Git ref names cannot contain `~`, so it is free to use as the escape marker:
  `~` becomes `~~` and `/` becomes `~/`. Both markers are URL-unreserved and
  legal in a file name, the pair is unambiguous, and the result stays readable
  for the common case — `feature/x` becomes `feature~/x`.

  The id names *refs*, not revision expressions in general, but escaping `~` as
  well as `/` means an expression like `HEAD~1` still round-trips rather than
  being silently rewritten into a path.
  """
  @spec ref_review_id(String.t(), String.t()) :: String.t()
  def ref_review_id(base, head) when is_binary(base) and is_binary(head) do
    "#{escape_ref(base)}..#{escape_ref(head)}"
  end

  @doc """
  The two refs a ref review id was built from.

  Returns `:error` for anything that is not a ref pair, including a GitHub
  pull request id, which is opaque to this function.
  """
  @spec parse_ref_review_id(String.t()) :: {:ok, {String.t(), String.t()}} | :error
  def parse_ref_review_id(review_id) when is_binary(review_id) do
    case String.split(review_id, "..") do
      [base, head] when base != "" and head != "" ->
        {:ok, {unescape_ref(base), unescape_ref(head)}}

      _other ->
        :error
    end
  end

  def parse_ref_review_id(_review_id), do: :error

  defp escape_ref(ref) do
    ref
    |> String.replace("~", "~~")
    |> String.replace("/", "~/")
  end

  defp unescape_ref(ref) do
    Regex.replace(~r/~~|~\//, ref, fn
      "~~" -> "~"
      "~/" -> "/"
    end)
  end

  defp safe_existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp readable(locator) do
    locator
    |> String.replace(~r/[^A-Za-z0-9]+/, "-")
    |> String.trim("-")
    |> String.downcase()
    |> String.slice(0, @slug_words)
    |> case do
      "" -> "project"
      readable -> readable
    end
  end

  defp digest(locator) do
    <<digest::binary-size(@digest_bytes), _rest::binary>> = :crypto.hash(:sha256, locator)
    Base.encode16(digest, case: :lower)
  end
end

defmodule Tackle.Web.AuthHTML do
  @moduledoc false

  use Phoenix.Component

  @doc "The HTTP status and the message shown for a failed sign-in."
  @spec failure(atom()) :: {pos_integer(), String.t()}
  def failure(:unknown_forge), do: {404, "There is no sign-in for that forge."}

  def failure(:sign_in_not_configured),
    do:
      {503,
       "Sign-in is not set up yet: the GitHub App's client id and client secret " <>
         "have to be stored first (see the app's README)."}

  def failure(:invalid_state),
    do: {400, "This sign-in expired or did not start here. Please try again."}

  def failure(:cancelled), do: {400, "The sign-in was cancelled on GitHub."}
  def failure(:forge_rejected), do: {502, "GitHub did not confirm the sign-in. Please try again."}

  def failure(:not_a_member),
    do:
      {403,
       "Your GitHub account is not a member of an organisation the app is installed on, " <>
         "so it cannot sign in here."}

  def failure(:membership_unverified),
    do: {502, "Your membership could not be checked with GitHub. Please try again later."}

  def failed(assigns) do
    ~H"""
    <main>
      <h1>Sign-in failed</h1>
      <p>{@message}</p>
      <p><a href="/">Back to the start page</a></p>
    </main>
    """
  end
end

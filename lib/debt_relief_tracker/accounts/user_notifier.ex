defmodule DebtReliefTracker.Accounts.UserNotifier do
  @moduledoc """
  Transactional emails about workspace access
  (docs/architecture/0002-auth-and-sharing-model.md): notifying an existing
  user they were added to a workspace, or inviting an email with no account
  yet to sign in and get access.

  Delivery is best-effort -- a failure is logged but never surfaces as an
  error, since granting workspace access must not depend on a third-party
  HTTP call succeeding.
  """

  import Swoosh.Email

  alias DebtReliefTracker.Mailer
  alias DebtReliefTracker.Accounts.{User, Workspace, WorkspaceInvitation}

  require Logger

  def deliver_workspace_shared(%User{email: nil}, _workspace, _inviter), do: :ok

  def deliver_workspace_shared(%User{} = user, %Workspace{} = workspace, %User{} = inviter) do
    new()
    |> to({user.display_name, user.email})
    |> from(from_address())
    |> subject("You've been added to #{workspace.name}")
    |> text_body("""
    Hi #{user.display_name},

    #{inviter.display_name} added you to the "#{workspace.name}" workspace \
    on Debt Relief Tracker. You can view it next time you log in.
    """)
    |> deliver()
  end

  def deliver_workspace_invitation(
        %WorkspaceInvitation{} = invitation,
        %Workspace{} = workspace,
        %User{} = inviter
      ) do
    login_url = DebtReliefTrackerWeb.Endpoint.url() <> "/auth/login"

    new()
    |> to(invitation.email)
    |> from(from_address())
    |> subject("You've been invited to #{workspace.name}")
    |> text_body("""
    Hi,

    #{inviter.display_name} invited you to the "#{workspace.name}" workspace \
    on Debt Relief Tracker. Sign in at #{login_url} using this email address \
    to get access -- you'll be added automatically.
    """)
    |> deliver()
  end

  defp from_address, do: Application.get_env(:debt_relief_tracker, :mailer)[:from]

  defp deliver(email) do
    case Mailer.deliver(email) do
      {:ok, _metadata} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to send email to #{inspect(email.to)}: #{inspect(reason)}")
        :ok
    end
  end
end

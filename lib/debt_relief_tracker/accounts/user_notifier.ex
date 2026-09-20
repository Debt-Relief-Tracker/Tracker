defmodule DebtReliefTracker.Accounts.UserNotifier do
  @moduledoc """
  Transactional emails about workspace access
  (docs/architecture/0002-auth-and-sharing-model.md): notifying an existing
  user they were added to a workspace, or inviting an email with no account
  yet to sign in and get access. Also the welcome email sent on signup.

  Delivery is best-effort -- a failure is logged but never surfaces as an
  error, since granting workspace access must not depend on a third-party
  HTTP call succeeding. Every attempt (sent or failed) is recorded via
  `Accounts.record_sent_email!/1` for the `/admin` sent-email log.
  """

  import Swoosh.Email

  alias DebtReliefTracker.{Accounts, Mailer, Settings}
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
    |> deliver(
      template: :workspace_shared,
      user_id: user.id,
      metadata: %{
        "workspace_id" => workspace.id,
        "inviter_id" => inviter.id,
        "user_id" => user.id
      }
    )
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
    |> deliver(
      template: :workspace_invitation,
      metadata: %{"invitation_id" => invitation.id}
    )
  end

  def deliver_welcome_email(%User{email: nil}), do: :ok

  def deliver_welcome_email(%User{} = user) do
    new()
    |> to({user.display_name, user.email})
    |> from(from_address())
    |> subject("Welcome to Debt Relief Tracker!")
    |> text_body("""
    Hi #{user.display_name},

    Welcome to Debt Relief Tracker! Congratulations on taking the first \
    step toward debt freedom -- every payment from here counts.

    "Do not owe anyone anything, except to love one another, for the one \
    who loves another has fulfilled the law." -- Romans 13:8 (CSB)
    """)
    |> deliver(template: :welcome, user_id: user.id, metadata: %{"user_id" => user.id})
  end

  defp from_address do
    settings = Settings.get_site_settings()

    case {settings.from_name, settings.from_email} do
      {name, email} when is_binary(name) and is_binary(email) and name != "" and email != "" ->
        {name, email}

      _ ->
        Application.get_env(:debt_relief_tracker, :mailer)[:from]
    end
  end

  defp deliver(email, opts) do
    {status, error} =
      case Mailer.deliver(email) do
        {:ok, _metadata} ->
          {:sent, nil}

        {:error, reason} ->
          Logger.error("Failed to send email to #{inspect(email.to)}: #{inspect(reason)}")
          {:failed, inspect(reason)}
      end

    Accounts.record_sent_email!(%{
      template: Keyword.fetch!(opts, :template),
      to: recipient_address(email),
      subject: email.subject,
      status: status,
      error: error,
      metadata: Keyword.get(opts, :metadata, %{}),
      user_id: Keyword.get(opts, :user_id)
    })

    :ok
  end

  defp recipient_address(%{to: [{_name, address} | _]}), do: address
end

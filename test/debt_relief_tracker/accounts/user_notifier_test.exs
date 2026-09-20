defmodule DebtReliefTracker.Accounts.UserNotifierTest do
  use DebtReliefTracker.DataCase

  import Swoosh.TestAssertions

  alias DebtReliefTracker.Accounts.{User, Workspace, WorkspaceInvitation, UserNotifier}

  describe "deliver_workspace_shared/3" do
    test "sends an email to the invitee naming the workspace and inviter" do
      user = %User{display_name: "Bea", email: "bea@example.com"}
      inviter = %User{display_name: "Alex"}
      workspace = %Workspace{name: "Household Debts"}

      assert :ok = UserNotifier.deliver_workspace_shared(user, workspace, inviter)

      assert_email_sent(
        to: {"Bea", "bea@example.com"},
        subject: "You've been added to Household Debts"
      )
    end

    test "no-ops for a user with no email" do
      user = %User{display_name: "Bea", email: nil}
      inviter = %User{display_name: "Alex"}
      workspace = %Workspace{name: "Household Debts"}

      assert :ok = UserNotifier.deliver_workspace_shared(user, workspace, inviter)
      assert_no_email_sent()
    end
  end

  describe "deliver_workspace_invitation/3" do
    test "sends an email to the invited address with a sign-in link" do
      invitation = %WorkspaceInvitation{email: "new@example.com"}
      inviter = %User{display_name: "Alex"}
      workspace = %Workspace{name: "Household Debts"}

      assert :ok = UserNotifier.deliver_workspace_invitation(invitation, workspace, inviter)

      assert_email_sent(to: "new@example.com", subject: "You've been invited to Household Debts")
    end
  end

  describe "deliver_welcome_email/1" do
    test "welcomes the new user with the Romans 13:8 (CSB) verse" do
      user = %User{display_name: "Bea", email: "bea@example.com"}

      assert :ok = UserNotifier.deliver_welcome_email(user)

      assert_email_sent(fn email ->
        assert email.to == [{"Bea", "bea@example.com"}]
        assert email.subject == "Welcome to Debt Relief Tracker!"

        assert email.text_body =~
                 "Do not owe anyone anything, except to love one another"

        assert email.text_body =~ "Romans 13:8 (CSB)"
      end)
    end

    test "no-ops for a user with no email" do
      user = %User{display_name: "Bea", email: nil}

      assert :ok = UserNotifier.deliver_welcome_email(user)
      assert_no_email_sent()
    end
  end
end

defmodule DebtReliefTracker.ActivityLogTest do
  use DebtReliefTracker.DataCase

  alias DebtReliefTracker.{Accounts, ActivityLog, Debts}

  setup do
    %{workspace: Accounts.ensure_default_workspace!()}
  end

  describe "list_recent/2" do
    test "preloads :user and :debt without raising", %{workspace: workspace} do
      {:ok, debt} =
        Debts.create_debt(workspace, nil, %{
          "name" => "Test Card",
          "type" => "revolving",
          "balance" => "1000.00",
          "apr" => "20.00",
          "minimum_payment_floor" => "25.00",
          "minimum_payment_rate" => "0.02"
        })

      [entry] = ActivityLog.list_recent(workspace)

      assert entry.action == :debt_added
      assert entry.debt.id == debt.id
      assert entry.user == nil
    end

    test "only returns entries for the given workspace, most recent first", %{
      workspace: workspace
    } do
      other_user =
        Accounts.get_or_create_user_from_oidc!(%{"sub" => "other", "email" => "other@example.com"})

      other_workspace = Accounts.current_workspace_for_user(other_user)

      {:ok, _} =
        Debts.create_debt(other_workspace, nil, %{
          "name" => "Other Workspace Card",
          "type" => "revolving",
          "balance" => "1.00",
          "apr" => "1.00",
          "minimum_payment_floor" => "1.00",
          "minimum_payment_rate" => "0.01"
        })

      {:ok, first} =
        Debts.create_debt(workspace, nil, %{
          "name" => "First",
          "type" => "revolving",
          "balance" => "1.00",
          "apr" => "1.00",
          "minimum_payment_floor" => "1.00",
          "minimum_payment_rate" => "0.01"
        })

      {:ok, _second} = Debts.update_debt(workspace, nil, first, %{"name" => "First (renamed)"})

      entries = ActivityLog.list_recent(workspace)

      assert Enum.map(entries, & &1.action) == [:debt_updated, :debt_added]
      assert Enum.all?(entries, &(&1.workspace_id == workspace.id))
    end
  end
end

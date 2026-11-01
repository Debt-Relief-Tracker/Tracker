defmodule DebtReliefTracker.MigrationHelpers do
  @moduledoc false

  import DebtReliefTracker.E2EEHelpers

  alias DebtReliefTracker.{Accounts, Debts, Payments, Repo, Settings}
  alias DebtReliefTracker.E2EE.Vaults

  @marker "ZQXMARKER7731"
  def marker, do: @marker

  @profile %{
    "current_age" => "30",
    "retirement_age" => "65",
    "current_retirement_savings" => "1000",
    "monthly_retirement_contribution" => "100",
    "monthly_gross_income" => "4000",
    "post_debt_investment_pct" => "15.0",
    "expected_annual_return_pct" => "7.0"
  }

  @doc "Fills `workspace` with one of everything; every free-text value carries `marker`."
  def populate!(workspace, user, marker \\ @marker) do
    {:ok, debt} =
      Debts.create_debt(workspace, user, %{
        "name" => "Card #{marker}",
        "type" => "revolving",
        "balance" => "1234.56",
        "apr" => "19.99",
        "minimum_payment_floor" => "25",
        "minimum_payment_rate" => "0.02"
      })

    {:ok, %{payment: payment}} =
      Payments.log_payment(workspace, user, debt, %{
        "amount" => "100.00",
        "paid_on" => "2026-01-15",
        "note" => "note #{marker}"
      })

    {:ok, _} =
      Settings.update_settings(Settings.get_settings!(workspace), %{
        "monthly_budget" => "1500.00",
        "currency" => "EUR"
      })

    {:ok, profile} =
      Settings.add_manual_retirement_profile(
        workspace,
        Map.merge(@profile, %{"name" => "Spouse #{marker}", "claim_email" => "#{marker}@x.test"})
      )

    %{debt: debt, payment: payment, profile: profile}
  end

  def create_vault!(workspace),
    do: {:ok, _} = Vaults.create(workspace, "v1.AAAA.BBBB", passphrase_wrap())

  @doc "Owner + workspace (+ optionally a member and a pending invitation)."
  def owner_ws(sub), do: (fn u -> {u, workspace_of(u)} end).(oidc_user(sub))

  def share!(workspace, owner, member_sub) do
    member = oidc_user(member_sub)
    {:ok, _} = Accounts.share_workspace_with_email(workspace, member.email, owner)
    member
  end

  def invite!(workspace, owner, email) do
    {:ok, _} = Accounts.share_workspace_with_email(workspace, email, owner)
  end

  @doc """
  Every row of every table (raw values plus any Cloak-decryptable cell,
  decrypted), as one searchable string. Used to prove a marker is gone.
  """
  def dump_all do
    repo = Repo.active_repo()

    {tables_sql, rows_sql} =
      if repo == DebtReliefTracker.Repo.Postgres do
        {"SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'",
         &"SELECT * FROM \"#{&1}\""}
      else
        {"SELECT name FROM sqlite_master WHERE type = 'table'", &"SELECT * FROM \"#{&1}\""}
      end

    for [table] <- repo.query!(tables_sql).rows, not String.starts_with?(table, "sqlite_") do
      for row <- repo.query!(rows_sql.(table)).rows, cell <- row do
        [inspect(cell, limit: :infinity, printable_limit: :infinity), decrypt(cell)]
      end
    end
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp decrypt(cell) when is_binary(cell) do
    case DebtReliefTracker.Vault.decrypt(cell) do
      {:ok, plain} -> plain
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp decrypt(_), do: ""

  def table_counts(workspace) do
    import Ecto.Query
    ws = workspace.id

    %{
      debts:
        Repo.aggregate(from(d in "debts", where: d.workspace_id == type(^ws, :binary_id)), :count),
      activity:
        Repo.aggregate(
          from(e in "activity_logs", where: e.workspace_id == type(^ws, :binary_id)),
          :count
        ),
      profiles:
        Repo.aggregate(
          from(r in "retirement_profiles", where: r.workspace_id == type(^ws, :binary_id)),
          :count
        ),
      payments:
        Repo.aggregate(
          from(p in "payments",
            join: d in "debts",
            on: d.id == p.debt_id,
            where: d.workspace_id == type(^ws, :binary_id)
          ),
          :count
        ),
      members:
        Repo.aggregate(
          from(m in "workspace_members", where: m.workspace_id == type(^ws, :binary_id)),
          :count
        ),
      invitations:
        Repo.aggregate(
          from(i in "workspace_invitations", where: i.workspace_id == type(^ws, :binary_id)),
          :count
        ),
      vaults:
        Repo.aggregate(
          from(v in "e2ee_vaults", where: v.workspace_id == type(^ws, :binary_id)),
          :count
        )
    }
  end
end

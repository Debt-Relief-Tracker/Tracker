defmodule DebtReliefTracker.PrecisionAuditTest do
  use DebtReliefTracker.DataCase

  import ExUnit.CaptureIO

  alias DebtReliefTracker.{Accounts, PrecisionAudit, Repo, Settings, Storage}
  alias DebtReliefTracker.Debts.Debt
  alias DebtReliefTracker.Payments.Payment
  alias DebtReliefTracker.Settings.RetirementProfile
  alias Mix.Tasks.Drt.AuditSnapshot

  defp d(s), do: Decimal.new(s)

  setup do
    %{workspace: Accounts.ensure_default_workspace!()}
  end

  defp insert_debt!(workspace, attrs) do
    Repo.insert!(
      struct!(
        %Debt{
          workspace_id: workspace.id,
          name: "Secret Lender Name",
          type: :revolving,
          balance: d("100.00"),
          apr: d("20.00")
        },
        attrs
      )
    )
  end

  defp insert_profile!(workspace, attrs) do
    Repo.insert!(
      struct!(
        %RetirementProfile{
          workspace_id: workspace.id,
          name: "Secret Person",
          current_age: 30,
          retirement_age: 65,
          current_retirement_savings: d("1000.00"),
          monthly_retirement_contribution: d("100.00"),
          monthly_gross_income: d("5000.00"),
          post_debt_investment_pct: d("15.00"),
          expected_annual_return_pct: d("7.00")
        },
        attrs
      )
    )
  end

  # A checksum of every row of every table plus the schema, via plain SELECTs.
  defp db_fingerprint do
    {:ok, %{rows: tables}} =
      Repo.active_repo().query(
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
      )

    for [table] <- tables, not String.starts_with?(table, "sqlite_"), into: %{} do
      {:ok, %{rows: rows}} =
        Repo.active_repo().query("SELECT * FROM \"#{table}\" ORDER BY rowid")

      {table, {length(rows), :erlang.phash2(rows, 4_294_967_296)}}
    end
    |> Map.put(
      :schema,
      Repo.active_repo().query!("SELECT type, name, sql FROM sqlite_master ORDER BY name").rows
    )
  end

  test "a clean workspace reports no precision loss", %{workspace: workspace} do
    insert_debt!(workspace, %{balance: d("1234.50"), apr: d("24.99")})
    insert_debt!(workspace, %{minimum_payment_rate: d("0.0200"), credit_limit: d("5000")})
    Settings.get_settings!(workspace)

    report = PrecisionAudit.run()
    assert report.findings == 0
    [ws] = report.workspaces
    assert ws.workspace_id == workspace.id
    assert ws.checked == %{debts: 2, payments: 0, settings: 1, retirement_profiles: 0}
    assert List.last(PrecisionAudit.format(report)) =~ "no precision loss"
  end

  test "reports every over-precise value across all four tables", %{workspace: workspace} do
    over = insert_debt!(workspace, %{balance: d("123.456"), apr: d("24.995")})

    rate =
      insert_debt!(workspace, %{minimum_payment_rate: d("0.02005"), credit_limit: d("100.001")})

    # Finer than the column's unit but numerically exact: no finding.
    ok = insert_debt!(workspace, %{balance: d("10.1000000")})

    payment =
      Repo.insert!(%Payment{
        debt_id: over.id,
        amount: d("50.005"),
        principal_portion: d("40.00"),
        interest_portion: d("10.005"),
        paid_on: ~D[2026-01-01]
      })

    setting = Settings.get_settings!(workspace)
    setting |> Ecto.Changeset.change(monthly_budget: d("1500.999")) |> Repo.update!()

    profile =
      insert_profile!(workspace, %{
        current_retirement_savings: d("2500.123"),
        expected_annual_return_pct: d("7.255")
      })

    report = PrecisionAudit.run()
    [ws] = report.workspaces

    found = fn table, col, id ->
      Enum.find(ws.findings, &({&1.table, &1.column, &1.id} == {table, col, id}))
    end

    assert %{decimals: 3, rounded: "123.46"} = found.("debts", "balance", over.id)
    assert %{decimals: 3, rounded: "25.00"} = found.("debts", "apr", over.id)
    assert %{decimals: 5, rounded: "0.0201"} = found.("debts", "minimum_payment_rate", rate.id)
    assert %{decimals: 3, rounded: "100.00"} = found.("debts", "credit_limit", rate.id)
    assert %{decimals: 3} = found.("payments", "amount", payment.id)
    assert %{decimals: 3} = found.("payments", "interest_portion", payment.id)
    assert %{decimals: 3, rounded: "1501.00"} = found.("settings", "monthly_budget", setting.id)

    assert %{decimals: 3, rounded: "2500.12"} =
             found.("retirement_profiles", "current_retirement_savings", profile.id)

    assert %{decimals: 3, rounded: "7.26"} =
             found.("retirement_profiles", "expected_annual_return_pct", profile.id)

    # Exactly those: nothing for the exact/clean columns.
    assert length(ws.findings) == 9
    refute Enum.any?(ws.findings, &(&1.id == ok.id))
    refute Enum.any?(ws.findings, &(&1.column == "principal_portion"))
    assert report.findings == 9
    assert ws.checked == %{debts: 3, payments: 1, settings: 1, retirement_profiles: 1}
  end

  test "findings agree with what the snapshot actually rounds", %{workspace: workspace} do
    debt = insert_debt!(workspace, %{balance: d("123.456"), apr: d("24.995")})
    {:ok, snapshot} = Storage.load(workspace)
    snap = Enum.find(snapshot.debts, &(&1.id == debt.id))
    assert snap.balance == 12_346
    assert snap.apr_bp == 2500

    [ws] = PrecisionAudit.run().workspaces
    assert Enum.map(ws.findings, & &1.column) |> Enum.sort() == ["apr", "balance"]
  end

  test "the report never contains names or other personal data", %{workspace: workspace} do
    insert_debt!(workspace, %{name: "Distinctive Lender Name", balance: d("1.005")})
    insert_profile!(workspace, %{name: "Distinctive Person", monthly_gross_income: d("1.005")})

    text = PrecisionAudit.run() |> PrecisionAudit.format() |> Enum.join("\n")
    assert text =~ "debts.balance id="
    refute text =~ "Distinctive"
    refute text =~ workspace.name
  end

  test "multiple workspaces are reported separately" do
    other_ws = Accounts.ensure_default_workspace!()
    user = Accounts.get_or_create_user_from_oidc!(%{"sub" => "other-sub", "name" => "Other"})
    second = Accounts.current_workspace_for_user(user)
    insert_debt!(second, %{balance: d("9.999")})
    insert_debt!(other_ws, %{balance: d("9.99")})

    report = PrecisionAudit.run()
    assert length(report.workspaces) == 2
    assert report.findings == 1
    assert [%{workspace_id: id}] = Enum.filter(report.workspaces, &(&1.findings != []))
    assert id == second.id
  end

  describe "mix drt.audit_snapshot" do
    test "exits 0 and prints the verdict when there is nothing to round", %{workspace: workspace} do
      insert_debt!(workspace, %{})

      out = capture_io(fn -> AuditSnapshot.run([]) end)
      assert out =~ "no precision loss"
      assert out =~ "workspace #{workspace.id}: checked debts=1"
    end

    test "exits non-zero when anything would round", %{workspace: workspace} do
      debt = insert_debt!(workspace, %{balance: d("0.001")})

      out =
        capture_io(fn ->
          assert catch_exit(AuditSnapshot.run([])) == {:shutdown, 1}
        end)

      assert out =~ "debts.balance id=#{debt.id} decimals=3 (would round to 0.00)"
      assert out =~ "PRECISION LOSS: 1"
    end

    test "never writes: every table and the schema are unchanged", %{workspace: workspace} do
      insert_debt!(workspace, %{balance: d("123.456")})
      insert_profile!(workspace, %{monthly_gross_income: d("5000.005")})
      Settings.get_settings!(workspace)
      before = db_fingerprint()

      capture_io(fn ->
        catch_exit(AuditSnapshot.run([]))
        PrecisionAudit.run()
      end)

      assert db_fingerprint() == before
    end

    test "starts SQLite read-only and Postgres with read-only transactions" do
      assert AuditSnapshot.read_only_opts(DebtReliefTracker.Repo.Sqlite)[:mode] == :readonly

      assert AuditSnapshot.read_only_opts(DebtReliefTracker.Repo.Postgres)[:parameters] ==
               [default_transaction_read_only: "on"]
    end

    test "never starts the application's boot, migrator or scheduler" do
      source = File.read!("lib/mix/tasks/drt.audit_snapshot.ex")
      code = source |> String.split("@impl Mix.Task") |> List.last()
      refute code =~ "ensure_all_started(:debt_relief_tracker)"
      refute code =~ "Boot.run"
      refute code =~ "Migrator"
      refute code =~ "Scheduler"
    end
  end
end

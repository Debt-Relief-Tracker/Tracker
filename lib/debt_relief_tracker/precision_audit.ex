defmodule DebtReliefTracker.PrecisionAudit do
  @moduledoc """
  Read-only audit of stored values that `DebtReliefTracker.Storage.Snapshot`
  would round (docs/architecture/0007-e2ee.md, "Precision audit").

  The snapshot is integer-only: money is rounded half up to cents, APR and
  retirement percentages to 0.01% (basis points), the minimum-payment rate
  to 0.0001 of the balance (0.01%). A stored Decimal finer than that loses
  the extra digits when a plaintext workspace is moved into the vault.

  This module only issues `SELECT`s through `DebtReliefTracker.Repo`. Each
  value is judged with the very same `Engine.Convert` round trip the
  snapshot uses, so "would round" here means exactly "the snapshot would
  change it". The report carries ids, column names, digit counts and the
  rounded value -- never names, notes or other personal data.
  """

  import Ecto.Query

  alias DebtReliefTracker.Accounts.Workspace
  alias DebtReliefTracker.Debts.Debt
  alias DebtReliefTracker.Engine.Convert
  alias DebtReliefTracker.Payments.Payment
  alias DebtReliefTracker.Repo
  alias DebtReliefTracker.Settings.RetirementProfile
  alias DebtReliefTracker.Settings.Setting

  @tables ~w(debts payments settings retirement_profiles)a

  # {column, unit}: the snapshot stores :cents, :percent_bp (24.99 -> 2499)
  # or :fraction_bp (0.0200 -> 200).
  @debt_columns [
    balance: :cents,
    original_balance: :cents,
    apr: :percent_bp,
    fixed_payment: :cents,
    minimum_payment_floor: :cents,
    minimum_payment_rate: :fraction_bp,
    credit_limit: :cents,
    statement_balance: :cents
  ]
  @payment_columns [amount: :cents, principal_portion: :cents, interest_portion: :cents]
  @setting_columns [monthly_budget: :cents]
  @profile_columns [
    current_retirement_savings: :cents,
    monthly_retirement_contribution: :cents,
    monthly_gross_income: :cents,
    post_debt_investment_pct: :percent_bp,
    expected_annual_return_pct: :percent_bp
  ]

  @type finding :: %{
          table: String.t(),
          column: String.t(),
          id: String.t(),
          decimals: non_neg_integer(),
          rounded: String.t()
        }
  @type workspace_report :: %{
          workspace_id: String.t(),
          checked: %{atom() => non_neg_integer()},
          findings: [finding()]
        }
  @type report :: %{workspaces: [workspace_report()], findings: non_neg_integer()}

  @doc "Audits every workspace. Read-only."
  @spec run() :: report()
  def run do
    debts = Repo.all(from(d in Debt, order_by: [asc: d.inserted_at, asc: d.id]))

    payments =
      Repo.all(
        from(p in Payment,
          join: d in assoc(p, :debt),
          order_by: [asc: p.inserted_at, asc: p.id],
          select: {d.workspace_id, p}
        )
      )

    settings = Repo.all(from(s in Setting, order_by: [asc: s.inserted_at, asc: s.id]))

    profiles =
      Repo.all(from(r in RetirementProfile, order_by: [asc: r.inserted_at, asc: r.id]))

    workspace_ids =
      (Repo.all(from(w in Workspace, order_by: [asc: w.inserted_at, asc: w.id], select: w.id)) ++
         Enum.map(debts, & &1.workspace_id) ++
         Enum.map(payments, &elem(&1, 0)) ++
         Enum.map(settings, & &1.workspace_id) ++ Enum.map(profiles, & &1.workspace_id))
      |> Enum.uniq()

    by_ws = fn rows, key -> Enum.group_by(rows, key) end
    debts_by = by_ws.(debts, & &1.workspace_id)
    payments_by = Enum.group_by(payments, &elem(&1, 0), &elem(&1, 1))
    settings_by = by_ws.(settings, & &1.workspace_id)
    profiles_by = by_ws.(profiles, & &1.workspace_id)

    workspaces =
      Enum.map(workspace_ids, fn id ->
        d = Map.get(debts_by, id, [])
        p = Map.get(payments_by, id, [])
        s = Map.get(settings_by, id, [])
        r = Map.get(profiles_by, id, [])

        %{
          workspace_id: id,
          checked: %{
            debts: length(d),
            payments: length(p),
            settings: length(s),
            retirement_profiles: length(r)
          },
          findings:
            scan("debts", d, @debt_columns) ++
              scan("payments", p, @payment_columns) ++
              scan("settings", s, @setting_columns) ++
              scan("retirement_profiles", r, @profile_columns)
        }
      end)

    %{
      workspaces: workspaces,
      findings: workspaces |> Enum.map(&length(&1.findings)) |> Enum.sum()
    }
  end

  @doc "The tables whose rows are checked."
  def tables, do: @tables

  defp scan(table, rows, columns) do
    for row <- rows, {column, unit} <- columns, finding = check(table, row, column, unit) do
      finding
    end
  end

  defp check(table, row, column, unit) do
    case Map.fetch!(row, column) do
      %Decimal{} = value ->
        if Decimal.nan?(value) or Decimal.inf?(value) do
          nil
        else
          rounded = round_trip(unit, value)

          if not Decimal.eq?(value, rounded) do
            %{
              table: table,
              column: to_string(column),
              id: row.id,
              decimals: decimals(value),
              rounded: Decimal.to_string(rounded, :normal)
            }
          end
        end

      _nil_or_other ->
        nil
    end
  end

  # Exactly what Storage.Snapshot stores and Convert reads back.
  defp round_trip(:cents, v), do: v |> Convert.to_cents() |> Convert.from_cents()
  defp round_trip(:percent_bp, v), do: v |> Convert.percent_to_bp() |> Convert.bp_to_percent()
  defp round_trip(:fraction_bp, v), do: v |> Convert.fraction_to_bp() |> Convert.bp_to_fraction()

  defp decimals(%Decimal{} = value) do
    case Decimal.normalize(value) do
      %Decimal{exp: exp} when exp < 0 -> -exp
      _ -> 0
    end
  end

  @doc "The report as printable lines (no personal data). Ends with the verdict."
  @spec format(report()) :: [String.t()]
  def format(%{workspaces: workspaces, findings: total}) do
    body =
      Enum.flat_map(workspaces, fn ws ->
        checked =
          Enum.map_join(@tables, " ", fn table -> "#{table}=#{Map.fetch!(ws.checked, table)}" end)

        ["workspace #{ws.workspace_id}: checked #{checked}"] ++
          Enum.map(ws.findings, fn f ->
            "  #{f.table}.#{f.column} id=#{f.id} decimals=#{f.decimals} (would round to #{f.rounded})"
          end)
      end)

    verdict =
      if total == 0,
        do: "no precision loss: every stored value fits the integer snapshot exactly",
        else: "PRECISION LOSS: #{total} stored value(s) would be rounded by the snapshot"

    body ++ [verdict]
  end
end

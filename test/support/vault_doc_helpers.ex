defmodule DebtReliefTracker.VaultDocHelpers do
  @moduledoc "Pure (no DB) helpers for VaultDoc tests: deterministic ctx and replica ops."

  alias DebtReliefTracker.VaultDoc
  alias DebtReliefTracker.VaultDoc.Ledger

  def ctx(opts \\ []) do
    %{
      now: Keyword.get(opts, :now, "2026-11-01T12:00:00Z"),
      today: Keyword.get(opts, :today, "2026-11-01"),
      new_id: Keyword.get(opts, :new_id, &Ecto.UUID.generate/0),
      actor: Keyword.get(opts, :actor, nil),
      members: Keyword.get(opts, :members)
    }
  end

  @doc "Applies a change that must succeed."
  def ok!(doc, change, opts \\ []) do
    case Ledger.apply_change(doc, change, ctx(opts)) do
      {:ok, doc} -> doc
      other -> raise "expected ok for #{inspect(change)}, got #{inspect(other)}"
    end
  end

  def card(attrs \\ %{}) do
    Map.merge(
      %{
        name: "Visa",
        type: "revolving",
        balance: 100_000,
        apr_bp: 2499,
        minimum_payment_floor: 3500,
        minimum_payment_rate_bp: 200
      },
      attrs
    )
  end

  def loan(attrs \\ %{}) do
    Map.merge(
      %{name: "Loan", type: "installment", balance: 500_000, apr_bp: 650, fixed_payment: 10_000},
      attrs
    )
  end

  def debt_id(doc, name) do
    doc
    |> VaultDoc.view()
    |> Map.fetch!(:debts)
    |> Enum.find(&(&1.name == name))
    |> Map.fetch!(:id)
  end

  def seconds(n),
    do: ~U[2026-11-01 12:00:00Z] |> DateTime.add(n, :second) |> DateTime.to_iso8601()
end

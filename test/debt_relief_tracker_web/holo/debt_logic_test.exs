defmodule DebtReliefTrackerWeb.Holo.DebtLogicTest do
  use ExUnit.Case, async: true

  alias DebtReliefTrackerWeb.Holo.DebtLogic

  @today "2026-10-31"

  defp debt(attrs) do
    Map.merge(
      %{
        id: "d1",
        name: "Visa",
        type: "revolving",
        status: "active",
        balance: 450_000,
        original_balance: nil,
        apr_bp: 2400,
        fixed_payment: nil,
        minimum_payment_floor: 3500,
        minimum_payment_rate_bp: 200,
        credit_limit: 1_000_000,
        exclude_from_plan: false,
        statement_balance: nil,
        statement_date: nil,
        position: 0,
        due_day: nil,
        auto_log_mode: "off",
        last_due_handled_on: nil,
        paid_off_at: nil,
        updated_at: nil
      },
      attrs
    )
  end

  defp snapshot(debts) do
    %{schema_version: 1, settings: %{currency: "USD"}, debts: debts, payments: [], activity: []}
  end

  describe "rows/2" do
    test "shows the balance, utilization and flags for the sidebar" do
      [row] = DebtLogic.rows(snapshot([debt(%{})]), @today)

      assert row.balance_text == "$4,500.00"
      assert row.revolving
      refute row.paid_off
      assert row.utilization_text == "45% utilization"
      refute row.item_class =~ "opacity-50"
    end

    test "no utilization without a credit limit; excluded debts are dimmed; paid off is struck through" do
      rows =
        DebtLogic.rows(
          snapshot([
            debt(%{id: "a", credit_limit: nil}),
            debt(%{id: "b", exclude_from_plan: true}),
            debt(%{id: "c", status: "paid_off"})
          ]),
          @today
        )

      [a, b, c] = rows
      assert a.utilization_text == nil
      assert b.item_class =~ "opacity-50"
      assert c.paid_off
      assert c.name_class =~ "line-through"
    end

    test "a revolving debt with a statement baseline shows the estimated balance" do
      d = debt(%{statement_balance: 450_000, statement_date: "2026-09-30", apr_bp: 2400})
      [row] = DebtLogic.rows(snapshot([d]), @today)

      # 31 days of 24% APR interest on $4,500 is more than the stored balance.
      assert row.balance_text != "$4,500.00"
      assert DebtLogic.estimated_balance(d, @today) > 450_000
    end
  end

  describe "due_prompts/2" do
    defp loan(attrs) do
      debt(
        Map.merge(
          %{
            id: "loan",
            name: "Auto Loan",
            type: "installment",
            fixed_payment: 15_000,
            auto_log_mode: "confirm",
            due_day: 31,
            minimum_payment_rate_bp: nil,
            minimum_payment_floor: nil,
            credit_limit: nil
          },
          attrs
        )
      )
    end

    test "a confirm-mode debt whose cycle is unhandled prompts, naming the cycle date" do
      assert [%{id: "loan", name: "Auto Loan", fixed_payment: 15_000, cycle: "2026-10-31"}] =
               DebtLogic.due_prompts(snapshot([loan(%{})]), @today)
    end

    test "before this month's due day, the prompt is for last month's cycle" do
      assert [%{cycle: "2026-09-30"}] = DebtLogic.due_prompts(snapshot([loan(%{})]), "2026-10-15")
    end

    test "handled cycles, automatic/off modes and revolving debts don't prompt" do
      debts = [
        loan(%{id: "done", last_due_handled_on: "2026-10-31"}),
        loan(%{id: "auto", auto_log_mode: "automatic"}),
        loan(%{id: "off", auto_log_mode: "off"}),
        debt(%{id: "card"})
      ]

      assert DebtLogic.due_prompts(snapshot(debts), @today) == []
    end
  end

  describe "debt_change/1" do
    test "a revolving debt becomes cents / basis points" do
      form = %{
        DebtLogic.debt_form(nil)
        | name: " Visa ",
          type: "revolving",
          balance: "4500.00",
          apr: "24.99",
          minimum_payment_floor: "35",
          minimum_payment_rate: "0.02",
          credit_limit: "10000"
      }

      assert {:ok, attrs} = DebtLogic.debt_change(form)

      assert attrs == %{
               name: "Visa",
               type: "revolving",
               balance: 450_000,
               original_balance: nil,
               apr_bp: 2499,
               minimum_payment_floor: 3500,
               minimum_payment_rate_bp: 200,
               credit_limit: 1_000_000,
               auto_log_mode: "off",
               exclude_from_plan: false
             }
    end

    test "an installment debt with confirm tracking needs a due day" do
      form = %{
        DebtLogic.debt_form(nil)
        | name: "New Loan",
          type: "installment",
          balance: "500.00",
          apr: "5.00",
          fixed_payment: "100.00",
          auto_log_mode: "confirm"
      }

      assert {:error, %{due_day: ["can't be blank"]}} = DebtLogic.debt_change(form)

      assert {:ok, attrs} = DebtLogic.debt_change(%{form | due_day: "15"})
      assert attrs.due_day == 15
      assert attrs.auto_log_mode == "confirm"
      assert attrs.fixed_payment == 10_000

      assert {:error, %{due_day: [_]}} = DebtLogic.debt_change(%{form | due_day: "32"})
      assert {:error, %{due_day: [_]}} = DebtLogic.debt_change(%{form | due_day: "x"})
    end

    test "tracking off sends no due day" do
      form = %{
        DebtLogic.debt_form(nil)
        | name: "Loan",
          type: "installment",
          balance: "500",
          apr: "5",
          fixed_payment: "100",
          due_day: "9"
      }

      assert {:ok, attrs} = DebtLogic.debt_change(form)
      refute Map.has_key?(attrs, :due_day)
    end

    test "rejects a missing type-specific required field" do
      form = %{
        DebtLogic.debt_form(nil)
        | name: "Bad Loan",
          type: "installment",
          balance: "500",
          apr: "5"
      }

      assert {:error, %{fixed_payment: ["can't be blank"]}} = DebtLogic.debt_change(form)

      revolving = %{form | type: "revolving"}
      assert {:error, %{minimum_payment_rate: ["can't be blank"]}} = DebtLogic.debt_change(revolving)
    end

    test "requires name, type, balance and apr; rejects junk and negatives" do
      assert {:error, errors} = DebtLogic.debt_change(DebtLogic.debt_form(nil))
      assert Map.keys(errors) |> Enum.sort() == [:apr, :balance, :name, :type]

      form = %{DebtLogic.debt_form(nil) | name: "x", type: "revolving", balance: "-1", apr: "abc"}
      assert {:error, %{balance: [_], apr: ["is invalid"]}} = DebtLogic.debt_change(form)
    end

    test "debt_form/1 round-trips an existing debt through debt_change/1" do
      d = debt(%{original_balance: 500_000})
      assert {:ok, attrs} = d |> DebtLogic.debt_form() |> DebtLogic.debt_change()

      assert attrs.balance == d.balance
      assert attrs.apr_bp == d.apr_bp
      assert attrs.minimum_payment_rate_bp == d.minimum_payment_rate_bp
      assert attrs.minimum_payment_floor == d.minimum_payment_floor
      assert attrs.credit_limit == d.credit_limit
      assert attrs.original_balance == 500_000
    end
  end

  describe "payment_attrs/1" do
    test "defaults the date to today and converts to cents" do
      form = %{DebtLogic.payment_form(@today) | amount: "250.50", note: " March "}
      assert {:ok, attrs} = DebtLogic.payment_attrs(form)

      assert attrs == %{
               amount: 25_050,
               principal_portion: nil,
               interest_portion: nil,
               paid_on: @today,
               note: "March"
             }
    end

    test "requires a positive amount and a real date" do
      assert {:error, %{amount: ["can't be blank"]}} = DebtLogic.payment_attrs(DebtLogic.payment_form(@today))

      form = %{DebtLogic.payment_form(@today) | amount: "0"}
      assert {:error, %{amount: ["must be greater than 0"]}} = DebtLogic.payment_attrs(form)

      form = %{DebtLogic.payment_form("2026-02-30") | amount: "5"}
      assert {:error, %{paid_on: ["is invalid"]}} = DebtLogic.payment_attrs(form)

      form = %{DebtLogic.payment_form("") | amount: "5"}
      assert {:error, %{paid_on: ["can't be blank"]}} = DebtLogic.payment_attrs(form)
    end

    test "valid_iso_date?/1" do
      assert DebtLogic.valid_iso_date?("2028-02-29")
      refute DebtLogic.valid_iso_date?("2026-02-29")
      refute DebtLogic.valid_iso_date?("2026-13-01")
      refute DebtLogic.valid_iso_date?("26-1-1")
      refute DebtLogic.valid_iso_date?("nope")
    end
  end

  describe "log all balances" do
    test "pre-fills active debts and builds a reconcile change per non-blank entry" do
      snap = snapshot([debt(%{id: "a"}), debt(%{id: "b", status: "paid_off"}), debt(%{id: "c", balance: 1000})])

      assert DebtLogic.balances_form(snap, @today) == %{"a" => "4500.00", "c" => "10.00"}

      assert {:ok, [{:reconcile_balance, "a", 400_000}]} =
               DebtLogic.balance_changes(snap, %{"a" => "4000.00", "c" => ""})

      assert {:error, %{"a" => ["is invalid"]}} = DebtLogic.balance_changes(snap, %{"a" => "x"})
      assert {:error, %{"a" => [_]}} = DebtLogic.balance_changes(snap, %{"a" => "-1"})
    end
  end

  test "error_text/1 flattens Storage errors" do
    assert DebtLogic.error_text({:invalid, %{balance: ["must be greater than or equal to 0"]}}) =~
             "balance must be"

    assert DebtLogic.error_text(:not_found) =~ "no longer exists"
  end
end

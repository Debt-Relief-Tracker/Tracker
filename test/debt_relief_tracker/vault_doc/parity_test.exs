defmodule DebtReliefTracker.VaultDoc.ParityTest do
  @moduledoc """
  Ledger vs Storage.Plain, scripted: after every step the vault view equals
  Plain's snapshot (see `DebtReliefTracker.VaultDocParity`).
  """
  use DebtReliefTracker.DataCase

  alias DebtReliefTracker.Accounts
  alias DebtReliefTracker.Debts.DueSchedule
  alias DebtReliefTracker.VaultDocParity, as: P

  setup do
    owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
    stranger = Accounts.get_or_create_user_from_oidc!(%{"sub" => "b", "email" => "b@example.com"})

    %{
      owner: owner,
      stranger: stranger,
      workspace: Accounts.current_workspace_for_user(owner)
    }
  end

  @card %{
    name: "Visa",
    type: "revolving",
    balance: 450_000,
    apr_bp: 2499,
    minimum_payment_floor: 3500,
    minimum_payment_rate_bp: 200,
    credit_limit: 1_000_000
  }

  @loan %{
    name: "Auto loan",
    type: "installment",
    balance: 1_200_000,
    apr_bp: 650,
    fixed_payment: 35_000
  }

  # Runs steps, returning the parity state; debts are found by name afterwards.
  defp run(p, changes),
    do: Enum.reduce(changes, p, fn change, p -> elem(P.step(p, change), 0) end)

  defp debt_id(p, name) do
    {:ok, snapshot} = DebtReliefTracker.Storage.Plain.load(p.workspace)
    Enum.find(snapshot.debts, &(&1.name == name)).id
  end

  defp err(p, change, opts \\ []) do
    {p, result} = P.step(p, change, opts)
    {p, result}
  end

  test "add_debt: both kinds, defaults, boundaries and big numbers", %{owner: o, workspace: w} do
    p = P.new(w, o)

    p =
      run(p, [
        {:add_debt, @card},
        {:add_debt, @loan},
        {:add_debt, %{@card | name: "Zero", balance: 0}},
        {:add_debt, %{@loan | name: "Big", balance: 999_999_999_999_999, fixed_payment: 1}},
        {:add_debt,
         Map.merge(@card, %{name: "Zoë's 😀 Karte \"quoted\"", position: 3, original_balance: 5})},
        {:add_debt,
         Map.merge(@card, %{
           name: "Full",
           exclude_from_plan: true,
           statement_balance: 400_000,
           statement_date: "2026-10-01",
           position: 2
         })},
        {:add_debt, Map.merge(@loan, %{name: "Auto", auto_log_mode: "confirm", due_day: 31})}
      ])

    assert length(p.doc.debts |> Map.keys()) == 7
  end

  test "add_debt validation errors match changeset errors", %{owner: o, workspace: w} do
    p = P.new(w, o)

    bad = [
      %{},
      %{@card | name: nil},
      %{@card | name: "   "},
      %{@card | name: ""},
      Map.delete(@card, :balance),
      %{@card | balance: -1},
      %{@card | apr_bp: -5},
      Map.put(@card, :original_balance, -1),
      %{@card | type: "other"},
      Map.delete(@card, :type),
      Map.delete(@card, :minimum_payment_rate_bp),
      Map.delete(@loan, :fixed_payment),
      %{@card | name: 5},
      Map.put(@card, :statement_date, "2026-02-30"),
      Map.put(@card, :statement_date, "nope"),
      Map.put(@card, :wat, 1),
      Map.put(@card, :status, "paid_off"),
      Map.put(@card, "name", "x"),
      Map.put(@card, :auto_log_mode, "confirm"),
      Map.put(@card, :auto_log_mode, "bogus"),
      Map.merge(@loan, %{auto_log_mode: "confirm"}),
      Map.merge(@loan, %{auto_log_mode: "automatic", due_day: 0}),
      Map.merge(@loan, %{auto_log_mode: "automatic", due_day: 32}),
      Map.merge(@card, %{auto_log_mode: "automatic", due_day: 40}),
      Map.put(@card, :exclude_from_plan, "yes"),
      Map.put(@card, :position, "a"),
      %{type: "installment", name: "", balance: -3, apr_bp: -1}
    ]

    p =
      Enum.reduce(bad, p, fn attrs, p ->
        {p, result} = err(p, {:add_debt, attrs})
        assert match?({:error, {:invalid, _}}, result), "accepted: #{inspect(attrs)}"
        {:error, {:invalid, errors}} = result
        assert map_size(errors) > 0
        p
      end)

    {:ok, snap} = DebtReliefTracker.Storage.Plain.load(p.workspace)
    assert snap.debts == []
    assert snap.activity == []
  end

  test "update_debt, mark_paid_off, delete and not_found", %{owner: o, workspace: w} do
    p = run(P.new(w, o), [{:add_debt, @card}, {:add_debt, @loan}])
    card = debt_id(p, "Visa")
    loan = debt_id(p, "Auto loan")
    ghost = Ecto.UUID.generate()

    p =
      run(p, [
        {:update_debt, card, %{name: "Visa Gold"}},
        {:update_debt, card, %{name: "Visa Gold"}},
        {:update_debt, card, %{balance: 300_000, apr_bp: 1999, credit_limit: nil}},
        {:update_debt, card, %{}},
        {:update_debt, card, %{statement_balance: 290_000, statement_date: "2026-10-15"}},
        {:update_debt, card, %{exclude_from_plan: true, position: 4}},
        {:update_debt, loan, %{auto_log_mode: "confirm", due_day: 5}},
        {:update_debt, loan, %{auto_log_mode: "off"}},
        {:update_debt, card, %{balance: 0}}
      ])

    errors = [
      {:update_debt, card, %{name: nil}},
      {:update_debt, card, %{name: ""}},
      {:update_debt, card, %{balance: -1}},
      {:update_debt, card, %{type: "installment"}},
      {:update_debt, loan, %{type: "revolving"}},
      {:update_debt, loan, %{fixed_payment: nil}},
      {:update_debt, card, %{auto_log_mode: "automatic"}},
      {:update_debt, loan, %{auto_log_mode: "automatic", due_day: 99}},
      {:update_debt, card, %{bogus: 1}},
      {:update_debt, card, %{status: "paid_off"}},
      {:update_debt, card, %{apr_bp: nil}},
      {:update_debt, ghost, %{name: "x"}},
      {:update_debt, "not-a-uuid", %{name: "x"}}
    ]

    p =
      Enum.reduce(errors, p, fn change, p ->
        {p, result} = err(p, change)
        assert {:error, _} = result
        p
      end)

    p =
      run(p, [
        {:mark_paid_off, card},
        {:mark_paid_off, card},
        {:update_debt, card, %{name: "Paid"}}
      ])

    {p, {:error, :not_found}} = err(p, {:mark_paid_off, ghost})
    p = run(p, [{:delete_debt, card}])
    {p, {:error, :not_found}} = err(p, {:delete_debt, card})
    {p, {:error, :not_found}} = err(p, {:update_debt, card, %{name: "x"}})
    {_p, {:error, :not_found}} = err(p, {:log_payment, card, %{amount: 1, paid_on: "2026-11-01"}})
  end

  test "log_payment: splits, defaults, boundaries, errors", %{owner: o, workspace: w} do
    p = run(P.new(w, o), [{:add_debt, @card}, {:add_debt, @loan}])
    card = debt_id(p, "Visa")
    loan = debt_id(p, "Auto loan")

    p =
      run(p, [
        {:log_payment, card, %{amount: 10_000, paid_on: "2026-10-31"}},
        {:log_payment, card,
         %{
           amount: 10_000,
           interest_portion: 3_000,
           principal_portion: 7_000,
           paid_on: "2026-10-30",
           note: "wk 1 – ünï \"q\""
         }},
        {:log_payment, card, %{amount: 5_000, interest_portion: 1_000, paid_on: "2026-10-30"}},
        {:log_payment, card,
         %{amount: 5_000, principal_portion: 0, paid_on: "2026-10-30", note: ""}},
        {:log_payment, card,
         %{amount: 5_000, principal_portion: 6_000, paid_on: "2026-10-29", note: nil}},
        {:log_payment, card, %{amount: 1, paid_on: "2026-10-29"}},
        {:log_payment, loan, %{amount: 1_199_999, paid_on: "2026-11-01"}},
        {:log_payment, loan, %{amount: 1, paid_on: "2026-11-01"}}
      ])

    errors = [
      {:log_payment, loan, %{amount: 1, paid_on: "2026-11-01"}},
      {:log_payment, card, %{amount: 0, paid_on: "2026-11-01"}},
      {:log_payment, card, %{amount: -5, paid_on: "2026-11-01"}},
      {:log_payment, card, %{paid_on: "2026-11-01", amount: 99_999_999}},
      {:log_payment, card, %{amount: 100, paid_on: "2026-13-01"}},
      {:log_payment, card, %{amount: 100, paid_on: "yesterday"}},
      {:log_payment, card, %{amount: 100, paid_on: nil}},
      {:log_payment, card, %{amount: 100, paid_on: "2026-11-01", extra: 1}},
      {:log_payment, card, %{amount: 100, paid_on: "2026-11-01", logged_by_user_id: "x"}},
      {:log_payment, card, %{amount: 100, paid_on: "2026-11-01", principal_portion: 99_999_999}}
    ]

    p =
      Enum.reduce(errors, p, fn change, p ->
        {p, result} = err(p, change)
        assert {:error, _} = result
        p
      end)

    # exactly the balance leaves zero (a boundary), and zero stays valid
    {:ok, snap} = DebtReliefTracker.Storage.Plain.load(p.workspace)
    balance = Enum.find(snap.debts, &(&1.id == card)).balance
    p = run(p, [{:log_payment, card, %{amount: balance, paid_on: "2026-11-01"}}])
    {:ok, snap} = DebtReliefTracker.Storage.Plain.load(p.workspace)
    assert Enum.find(snap.debts, &(&1.id == card)).balance == 0

    {_p, {:error, {:invalid, %{balance: _}}}} =
      err(p, {:log_payment, card, %{amount: 1, paid_on: "2026-11-01"}})
  end

  test "delete cascades to payments and unlinks activity", %{owner: o, workspace: w} do
    p = run(P.new(w, o), [{:add_debt, @card}, {:add_debt, @loan}])
    card = debt_id(p, "Visa")
    loan = debt_id(p, "Auto loan")

    p =
      run(p, [
        {:log_payment, card, %{amount: 1000, paid_on: "2026-11-01"}},
        {:log_payment, loan, %{amount: 2000, paid_on: "2026-11-01"}},
        {:log_payment, card, %{amount: 3000, paid_on: "2026-11-02"}},
        {:delete_debt, card}
      ])

    {:ok, snap} = DebtReliefTracker.Storage.Plain.load(p.workspace)
    assert length(snap.payments) == 1
    assert Enum.any?(snap.activity, &(&1.debt_id == nil and &1.action == "debt_deleted"))
    run(p, [{:add_debt, @card}, {:delete_debt, loan}])
  end

  test "mark_paid_off then deleted debts keep activity consistent", %{owner: o, workspace: w} do
    p = run(P.new(w, o), [{:add_debt, @card}])
    card = debt_id(p, "Visa")

    run(p, [
      {:mark_paid_off, card},
      {:log_payment, card, %{amount: 10, paid_on: "2026-11-01"}},
      {:delete_debt, card}
    ])
  end

  test "actor nil and a signed-in actor produce the same entries", %{workspace: w} do
    p = P.new(w, nil)
    {p, {:ok, _}} = P.step(p, {:add_debt, @card}, actor: nil)
    card = debt_id(p, "Visa")

    {p, {:ok, _}} =
      P.step(p, {:log_payment, card, %{amount: 5000, paid_on: "2026-11-01"}}, actor: nil)

    {_p, {:ok, snap}} = P.step(p, {:update_debt, card, %{name: "V"}}, actor: nil)
    assert Enum.all?(snap.activity, &is_nil(&1.user_id))
  end

  describe "reconcile_balance" do
    test "without interest estimate: gap becomes a principal payment", %{owner: o, workspace: w} do
      p = run(P.new(w, o), [{:add_debt, @card}, {:add_debt, @loan}])
      card = debt_id(p, "Visa")
      loan = debt_id(p, "Auto loan")

      run(p, [
        {:reconcile_balance, card, 400_000},
        {:reconcile_balance, card, 400_000},
        {:reconcile_balance, card, 450_000},
        {:reconcile_balance, card, 100},
        {:reconcile_balance, loan, 1_000_000},
        {:reconcile_balance, loan, 1_000_000}
      ])
    end

    test "with an estimated-interest overlay splits the gap", %{owner: o, workspace: w} do
      p = run(P.new(w, o), [{:add_debt, @card}, {:add_debt, @loan}])
      card = debt_id(p, "Visa")
      back = Date.utc_today() |> Date.add(-37) |> Date.to_iso8601()

      p =
        run(p, [
          {:update_debt, card, %{statement_balance: 450_000, statement_date: back}},
          {:reconcile_balance, card, 440_000},
          {:update_debt, card, %{statement_balance: 440_000, statement_date: back}},
          {:reconcile_balance, card, 445_000},
          {:update_debt, card, %{statement_date: back, statement_balance: 445_000, apr_bp: 9999}},
          # gap smaller than the accrued interest: all interest, no principal
          {:reconcile_balance, card, 444_000},
          {:update_debt, card, %{statement_date: back}},
          {:reconcile_balance, card, 449_999},
          {:update_debt, card, %{statement_date: back}},
          {:reconcile_balance, card, 5_000}
        ])

      {:ok, snap} = DebtReliefTracker.Storage.Plain.load(p.workspace)
      assert Enum.any?(snap.payments, &(&1.interest_portion > 0))
    end

    test "errors", %{owner: o, workspace: w} do
      p = run(P.new(w, o), [{:add_debt, @card}])
      card = debt_id(p, "Visa")
      {p, {:error, :not_found}} = err(p, {:reconcile_balance, Ecto.UUID.generate(), 5})
      {_p, {:error, {:invalid, %{balance: _}}}} = err(p, {:reconcile_balance, card, -100})
    end
  end

  describe "handle_due" do
    defp cycle_for(due_day) do
      DueSchedule.current_cycle_due_date(%{due_day: due_day}, Date.utc_today())
    end

    test "post, skip, not_due and guards", %{owner: o, workspace: w} do
      p =
        run(P.new(w, o), [
          {:add_debt,
           Map.merge(@loan, %{name: "Confirm", auto_log_mode: "confirm", due_day: 15})},
          {:add_debt, Map.merge(@loan, %{name: "Auto", auto_log_mode: "automatic", due_day: 1})},
          {:add_debt, Map.merge(@loan, %{name: "Off", auto_log_mode: "off", due_day: 3})},
          {:add_debt, @card}
        ])

      confirm = debt_id(p, "Confirm")
      auto = debt_id(p, "Auto")
      off = debt_id(p, "Off")
      card = debt_id(p, "Visa")
      c15 = cycle_for(15) |> Date.to_iso8601()
      c1 = cycle_for(1) |> Date.to_iso8601()
      future = Date.utc_today() |> Date.add(40) |> Date.to_iso8601()

      p = run(p, [{:handle_due, confirm, :post, c15}])
      # second time: already handled
      {p, {:error, :not_due}} = err(p, {:handle_due, confirm, :post, c15})
      {p, {:error, :not_due}} = err(p, {:handle_due, confirm, :skip, c15})
      p = run(p, [{:handle_due, auto, :skip, c1}])

      for change <- [
            {:handle_due, auto, :post, c1},
            {:handle_due, off, :post, "2026-10-03"},
            {:handle_due, card, :post, c15},
            {:handle_due, confirm, :post, future},
            {:handle_due, confirm, :post, "2026-10-14"},
            {:handle_due, confirm, :post, "garbage"}
          ] do
        {_p, result} = err(p, change)
        assert {:error, _} = result
      end

      {_p, {:error, :not_found}} = err(p, {:handle_due, Ecto.UUID.generate(), :post, c15})
    end

    test "posting without a user logs payment_auto_logged", %{owner: o, workspace: w} do
      p =
        run(P.new(w, o), [{:add_debt, Map.merge(@loan, %{auto_log_mode: "confirm", due_day: 10})}])

      id = debt_id(p, "Auto loan")

      {p, {:ok, snap}} =
        P.step(p, {:handle_due, id, :post, Date.to_iso8601(cycle_for(10))}, actor: nil)

      assert Enum.any?(snap.activity, &(&1.action == "payment_auto_logged"))

      assert Enum.find(snap.debts, &(&1.id == id)).last_due_handled_on ==
               Date.to_iso8601(cycle_for(10))

      _ = p
    end

    test "a fixed payment larger than the balance is rejected and not stamped", %{
      owner: o,
      workspace: w
    } do
      p =
        run(P.new(w, o), [
          {:add_debt, Map.merge(@loan, %{balance: 100, auto_log_mode: "confirm", due_day: 10})}
        ])

      id = debt_id(p, "Auto loan")
      c = Date.to_iso8601(cycle_for(10))
      {p, {:error, {:invalid, %{balance: _}}}} = err(p, {:handle_due, id, :post, c})
      run(p, [{:handle_due, id, :skip, c}])
    end

    test "clamped due days (31st in short months) and older unhandled cycles", %{
      owner: o,
      workspace: w
    } do
      p =
        run(P.new(w, o), [{:add_debt, Map.merge(@loan, %{auto_log_mode: "confirm", due_day: 31})}])

      id = debt_id(p, "Auto loan")
      today = Date.utc_today()
      prev = Date.beginning_of_month(today) |> Date.add(-1)

      run(p, [
        {:handle_due, id, :post, Date.to_iso8601(cycle_for(31))},
        {:handle_due, id, :post, Date.to_iso8601(prev)}
      ])
    end
  end

  describe "settings" do
    test "updates, dismissal and errors", %{owner: o, workspace: w} do
      p = P.new(w, o)

      p =
        run(p, [
          {:update_settings, %{monthly_budget: 150_000}},
          {:update_settings, %{currency: "EUR", budget_mode: "margin"}},
          {:update_settings, %{retirement_onboarding_dismissed: true}},
          {:update_settings, %{monthly_budget: nil}},
          {:update_settings, %{}},
          {:update_settings, %{currency: ""}},
          {:update_settings, %{budget_mode: " "}},
          {:update_settings, %{monthly_budget: 999_999_999_999_999}}
        ])

      for change <- [
            {:update_settings, %{currency: nil}},
            {:update_settings, %{budget_mode: "weekly"}},
            {:update_settings, %{retirement_onboarding_dismissed: "x"}},
            {:update_settings, %{nope: 1}},
            {:update_settings, %{currency: "USD", nope: 1}}
          ] do
        {_p, result} = err(p, change)
        assert {:error, {:invalid, _}} = result
      end
    end
  end

  describe "retirement profiles" do
    @profile %{
      current_age: 30,
      retirement_age: 65,
      current_retirement_savings: 1_000_050,
      monthly_retirement_contribution: 10_000,
      monthly_gross_income: 500_000,
      post_debt_investment_bp: 1500,
      expected_annual_return_bp: 750
    }

    test "member and manual profiles, updates, deletes", %{owner: o, workspace: w} do
      p = P.new(w, o)

      p =
        run(p, [
          {:add_member_retirement_profile, o.id, @profile},
          {:add_manual_retirement_profile,
           Map.merge(@profile, %{name: "Sam", claim_email: "sam@example.com"})},
          {:add_manual_retirement_profile, Map.merge(@profile, %{name: "Pat 😀"})},
          {:add_manual_retirement_profile,
           Map.merge(@profile, %{name: "Pat again", claim_email: nil})}
        ])

      {:ok, snap} = DebtReliefTracker.Storage.Plain.load(p.workspace)
      [member, sam, pat | _] = snap.retirement_profiles

      p =
        run(p, [
          {:update_retirement_profile, member.id,
           %{current_age: 31, name: "ignored", claim_email: "x@y.z"}},
          {:update_retirement_profile, sam.id,
           %{name: "Samantha", claim_email: "samantha@example.com"}},
          {:update_retirement_profile, sam.id, %{claim_email: nil}},
          {:update_retirement_profile, pat.id,
           %{retirement_age: 70, expected_annual_return_bp: 3000, post_debt_investment_bp: 10_000}},
          {:update_retirement_profile, pat.id, %{}},
          {:update_retirement_profile, pat.id, %{claim_email: "sam@example.com"}},
          {:delete_retirement_profile, sam.id},
          {:add_manual_retirement_profile,
           Map.merge(@profile, %{name: "Reuse", claim_email: "sam@example.com"})}
        ])

      {:ok, snap2} = DebtReliefTracker.Storage.Plain.load(p.workspace)
      _ = snap2

      {p, {:ok, _}} =
        err(
          p,
          {:add_manual_retirement_profile,
           Map.merge(@profile, %{name: "Dupmail", claim_email: "dup@example.com"})}
        )

      for change <- [
            {:add_member_retirement_profile, o.id, @profile},
            {:update_retirement_profile, pat.id, %{claim_email: "dup@example.com"}},
            {:add_manual_retirement_profile,
             Map.merge(@profile, %{name: "Dup", claim_email: "sam@example.com"})}
          ] do
        {_p, result} = err(p, change)
        assert match?({:error, {:invalid, _}}, result), "accepted: #{inspect(change)}"
      end

      {p, {:error, :not_found}} = err(p, {:delete_retirement_profile, sam.id})
      {p, {:error, :not_found}} = err(p, {:update_retirement_profile, Ecto.UUID.generate(), %{}})
      _ = p
    end

    test "validation errors and a non-member", %{owner: o, stranger: s, workspace: w} do
      p = P.new(w, o)
      {p, {:error, :not_found}} = err(p, {:add_member_retirement_profile, s.id, @profile})

      {p, {:error, :not_found}} =
        err(p, {:add_member_retirement_profile, Ecto.UUID.generate(), @profile})

      bad = [
        %{},
        %{@profile | current_age: -1},
        %{@profile | current_age: 121},
        %{@profile | retirement_age: 0},
        %{@profile | retirement_age: 30},
        %{@profile | retirement_age: 29},
        %{@profile | current_retirement_savings: -1},
        %{@profile | monthly_retirement_contribution: -1},
        %{@profile | monthly_gross_income: -1},
        %{@profile | post_debt_investment_bp: -1},
        %{@profile | post_debt_investment_bp: 10_001},
        %{@profile | expected_annual_return_bp: 3001},
        %{@profile | expected_annual_return_bp: -1},
        Map.put(@profile, :bogus, 1),
        Map.delete(@profile, :current_age),
        %{@profile | retirement_age: 0, current_age: 0}
      ]

      p =
        Enum.reduce(bad, p, fn attrs, p ->
          {p, r1} = err(p, {:add_member_retirement_profile, o.id, attrs})
          {p, r2} = err(p, {:add_manual_retirement_profile, Map.put(attrs, :name, "N")})
          assert {:error, _} = r1
          assert {:error, _} = r2
          p
        end)

      {p, {:error, {:invalid, %{name: _}}}} = err(p, {:add_manual_retirement_profile, @profile})

      {_p, {:error, {:invalid, %{name: _}}}} =
        err(p, {:add_manual_retirement_profile, Map.put(@profile, :name, "  ")})
    end
  end

  test "unknown changes are rejected, never raised", %{owner: o, workspace: w} do
    p = P.new(w, o)
    {:ok, _} = DebtReliefTracker.Storage.Plain.load(w)

    for change <- [:nope, {:add_debt, nil}, {:add_debt, "x"}, {}, {:log_payment, 1}, nil, 5] do
      ctx = %{
        now: "2026-11-01T12:00:00Z",
        today: "2026-11-01",
        new_id: &Ecto.UUID.generate/0,
        actor: nil
      }

      assert {:error, {:invalid, _}} =
               DebtReliefTracker.VaultDoc.Ledger.apply_change(p.doc, change, ctx)
    end
  end
end

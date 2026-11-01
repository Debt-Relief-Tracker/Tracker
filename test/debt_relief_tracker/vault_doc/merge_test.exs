defmodule DebtReliefTracker.VaultDoc.MergeTest do
  use ExUnit.Case, async: true

  import DebtReliefTracker.VaultDocHelpers

  alias DebtReliefTracker.VaultDoc
  alias DebtReliefTracker.VaultDoc.{Ledger, Merge}

  defp base do
    VaultDoc.new()
    |> ok!({:add_debt, card()}, now: seconds(0))
    |> ok!({:add_debt, loan()}, now: seconds(1))
  end

  defp bal(doc, name) do
    doc
    |> VaultDoc.view()
    |> Map.fetch!(:debts)
    |> Enum.find(&(&1.name == name))
    |> Map.fetch!(:balance)
  end

  describe "concurrent payments" do
    test "payments logged on two devices both reduce the balance, once" do
      b = base()
      id = debt_id(b, "Visa")
      a = ok!(b, {:log_payment, id, %{amount: 10_000, paid_on: "2026-11-02"}}, now: seconds(10))
      c = ok!(b, {:log_payment, id, %{amount: 2_500, paid_on: "2026-11-02"}}, now: seconds(20))

      m = Merge.merge(a, c)
      assert bal(m, "Visa") == 100_000 - 12_500
      assert m == Merge.merge(c, a)
      assert length(VaultDoc.view(m).payments) == 2
      assert Merge.merge(m, a) == m
      assert Merge.merge(m, c) == m
      assert Merge.merge(m, m) == m
    end

    test "a payment on one device and a rename on the other both survive (either clock order)" do
      b = base()
      id = debt_id(b, "Visa")
      pay = ok!(b, {:log_payment, id, %{amount: 4_000, paid_on: "2026-11-02"}}, now: seconds(50))
      ren = ok!(b, {:update_debt, id, %{name: "Visa Gold"}}, now: seconds(30))
      ren_later = ok!(b, {:update_debt, id, %{name: "Visa Gold"}}, now: seconds(90))

      for r <- [ren, ren_later] do
        m = Merge.merge(pay, r)
        assert bal(m, "Visa Gold") == 96_000
        assert m == Merge.merge(r, pay)
      end
    end

    test "a payment concurrent with a new balance baseline lowers the new baseline" do
      b = base()
      id = debt_id(b, "Visa")
      pay = ok!(b, {:log_payment, id, %{amount: 4_000, paid_on: "2026-11-02"}}, now: seconds(10))
      edit = ok!(b, {:update_debt, id, %{balance: 70_000}}, now: seconds(20))
      m = Merge.merge(pay, edit)
      assert bal(m, "Visa") == 66_000
      assert m == Merge.merge(edit, pay)
    end

    test "a payment made after seeing the new baseline is not subtracted twice" do
      b = base()
      id = debt_id(b, "Visa")
      edit = ok!(b, {:update_debt, id, %{balance: 70_000}}, now: seconds(20))

      then_pay =
        ok!(edit, {:log_payment, id, %{amount: 1_000, paid_on: "2026-11-03"}}, now: seconds(30))

      assert bal(Merge.merge(then_pay, edit), "Visa") == 69_000
      assert bal(Merge.merge(edit, then_pay), "Visa") == 69_000
      assert bal(Merge.merge(then_pay, b), "Visa") == 69_000
    end

    test "same deterministic auto payment on two devices is one payment applied once" do
      b =
        VaultDoc.new()
        |> ok!({:add_debt, loan(%{auto_log_mode: "automatic", due_day: 5})}, now: seconds(0))

      c1 = ctx(today: "2026-11-10", now: seconds(100))
      c2 = ctx(today: "2026-11-10", now: seconds(200))
      {:ok, d1, r1} = Ledger.catch_up(b, c1)
      {:ok, d2, _} = Ledger.catch_up(b, c2)
      assert [%{cycle: "2026-11-05"}] = r1.posted
      m = Merge.merge(d1, d2)
      assert bal(m, "Loan") == 490_000
      assert length(VaultDoc.view(m).payments) == 1
      assert length(VaultDoc.view(m).activity) == 2
      assert m == Merge.merge(d2, d1)
      {:ok, again, r} = Ledger.catch_up(m, ctx(today: "2026-11-10", now: seconds(300)))
      assert again == m and r.posted == []
    end

    test "concurrent differing principals for the same payment id converge" do
      b =
        VaultDoc.new()
        |> ok!({:add_debt, loan(%{auto_log_mode: "automatic", due_day: 5})}, now: seconds(0))

      id = debt_id(b, "Loan")
      a = ok!(b, {:update_debt, id, %{fixed_payment: 20_000}}, now: seconds(5))
      {:ok, d1, _} = Ledger.catch_up(a, ctx(today: "2026-11-10", now: seconds(100)))
      {:ok, d2, _} = Ledger.catch_up(b, ctx(today: "2026-11-10", now: seconds(200)))
      m = Merge.merge(d1, d2)
      assert m == Merge.merge(d2, d1)
      [payment] = VaultDoc.view(m).payments
      assert bal(m, "Loan") == 500_000 - payment.principal_portion
    end
  end

  describe "tombstones" do
    test "a delete beats an older edit; a strictly newer edit resurrects with its payments" do
      b = base()
      id = debt_id(b, "Visa")
      b = ok!(b, {:log_payment, id, %{amount: 1_000, paid_on: "2026-11-02"}}, now: seconds(5))
      del = ok!(b, {:delete_debt, id}, now: seconds(50))
      old_edit = ok!(b, {:update_debt, id, %{name: "Old"}}, now: seconds(40))
      new_edit = ok!(b, {:update_debt, id, %{name: "New"}}, now: seconds(60))

      m = Merge.merge(del, old_edit)
      assert m == Merge.merge(old_edit, del)
      assert Enum.map(VaultDoc.view(m).debts, & &1.name) == ["Loan"]
      assert VaultDoc.view(m).payments == []

      m = Merge.merge(del, new_edit)
      assert m == Merge.merge(new_edit, del)
      assert "New" in Enum.map(VaultDoc.view(m).debts, & &1.name)
      assert length(VaultDoc.view(m).payments) == 1
      assert bal(m, "New") == 99_000
    end

    test "a payment logged elsewhere after the delete does not resurrect the debt" do
      b = base()
      id = debt_id(b, "Visa")
      del = ok!(b, {:delete_debt, id}, now: seconds(10))
      pay = ok!(b, {:log_payment, id, %{amount: 1_000, paid_on: "2026-11-02"}}, now: seconds(99))
      m = Merge.merge(del, pay)
      assert m == Merge.merge(pay, del)
      assert Enum.map(VaultDoc.view(m).debts, & &1.name) == ["Loan"]
      assert VaultDoc.view(m).payments == []
    end

    test "equal stamps: the tombstone wins" do
      b = base()
      id = debt_id(b, "Visa")
      del = ok!(b, {:delete_debt, id}, now: seconds(10))
      edit = ok!(b, {:update_debt, id, %{name: "E"}}, now: seconds(10))
      assert Merge.merge(del, edit) == Merge.merge(edit, del)
      assert Enum.map(VaultDoc.view(Merge.merge(del, edit)).debts, & &1.name) == ["Loan"]
    end
  end

  describe "settings and profiles" do
    test "settings merge per key" do
      b = base()
      a = ok!(b, {:update_settings, %{monthly_budget: 150_000}}, now: seconds(10))
      c = ok!(b, {:update_settings, %{currency: "EUR"}}, now: seconds(5))
      m = Merge.merge(a, c)
      assert %{monthly_budget: 150_000, currency: "EUR"} = VaultDoc.view(m).settings
      assert m == Merge.merge(c, a)

      c2 = ok!(b, {:update_settings, %{monthly_budget: 99}}, now: seconds(20))
      assert VaultDoc.view(Merge.merge(a, c2)).settings.monthly_budget == 99
      tie = ok!(b, {:update_settings, %{monthly_budget: 7}}, now: seconds(10))
      assert Merge.merge(a, tie) == Merge.merge(tie, a)
    end

    test "profiles: per-record LWW with tombstones" do
      attrs = %{
        current_age: 30,
        retirement_age: 65,
        current_retirement_savings: 0,
        monthly_retirement_contribution: 0,
        monthly_gross_income: 0,
        post_debt_investment_bp: 1500,
        expected_annual_return_bp: 700
      }

      b =
        ok!(base(), {:add_manual_retirement_profile, Map.put(attrs, :name, "Sam")},
          now: seconds(2)
        )

      id = hd(VaultDoc.view(b).retirement_profiles).id
      e1 = ok!(b, {:update_retirement_profile, id, %{current_age: 31}}, now: seconds(10))
      e2 = ok!(b, {:update_retirement_profile, id, %{current_age: 32}}, now: seconds(20))
      d = ok!(b, {:delete_retirement_profile, id}, now: seconds(15))
      assert hd(VaultDoc.view(Merge.merge(e1, e2)).retirement_profiles).current_age == 32
      assert VaultDoc.view(Merge.merge(e1, d)).retirement_profiles == []
      assert hd(VaultDoc.view(Merge.merge(e2, d)).retirement_profiles).current_age == 32
      assert Merge.merge(e2, d) == Merge.merge(d, e2)
    end
  end

  test "activity is a union and an unknown device's records are all kept" do
    b = base()
    a = ok!(b, {:add_debt, card(%{name: "A"})}, now: seconds(10))
    c = ok!(b, {:add_debt, card(%{name: "C"})}, now: seconds(10))
    m = Merge.merge(a, c)
    assert length(VaultDoc.view(m).debts) == 4
    assert length(VaultDoc.view(m).activity) == 4
  end

  # --- property-style ----------------------------------------------------------

  defp random_op(doc, rep, step) do
    view = VaultDoc.view(doc)
    now = seconds(:rand.uniform(40) + step * 2)
    ids = Enum.map(view.debts, & &1.id)
    id = if ids == [], do: Ecto.UUID.generate(), else: Enum.random(ids)

    change =
      case :rand.uniform(12) do
        1 ->
          {:add_debt,
           Enum.random([
             card(%{name: "c#{rep}#{step}"}),
             loan(%{name: "l#{rep}#{step}", auto_log_mode: "automatic", due_day: 5})
           ])}

        2 ->
          {:update_debt, id, %{name: "r#{rep}#{step}"}}

        3 ->
          {:update_debt, id, %{balance: :rand.uniform(200_000)}}

        n when n in [4, 5, 6, 7] ->
          {:log_payment, id, %{amount: :rand.uniform(3_000), paid_on: "2026-11-02"}}

        8 ->
          {:delete_debt, id}

        9 ->
          {:mark_paid_off, id}

        10 ->
          {:update_settings,
           Enum.random([
             %{monthly_budget: :rand.uniform(9_999)},
             %{currency: Enum.random(["USD", "EUR"])}
           ])}

        11 ->
          {:handle_due, id, Enum.random([:post, :skip]), "2026-11-05"}

        12 ->
          {:reconcile_balance, id, :rand.uniform(150_000)}
      end

    case Ledger.apply_change(doc, change, ctx(now: now, today: "2026-11-10", actor: nil)) do
      {:ok, d} -> d
      {:error, _} -> doc
    end
  end

  defp replica(base, rep, steps),
    do: Enum.reduce(1..steps, base, fn step, d -> random_op(d, rep, step) end)

  for seed <- 1..60 do
    test "merge is commutative, associative and idempotent (seed #{seed})" do
      :rand.seed(:exsss, {unquote(seed), 3, 9})

      b =
        Enum.reduce(1..3, VaultDoc.new(), fn i, d ->
          ok!(
            d,
            {:add_debt,
             Enum.random([
               card(%{name: "b#{i}"}),
               loan(%{name: "bl#{i}", auto_log_mode: "automatic", due_day: 5})
             ])}, now: seconds(i))
        end)

      a = replica(b, "a", 10)
      c = replica(b, "c", 10)
      d = replica(Merge.merge(b, a), "d", 6)

      assert Merge.merge(a, c) == Merge.merge(c, a)
      assert Merge.merge(a, a) == a
      m = Merge.merge(a, c)
      assert Merge.merge(m, a) == m
      assert Merge.merge(m, c) == m
      assert Merge.merge(m, m) == m
      assert Merge.merge(Merge.merge(a, c), d) == Merge.merge(a, Merge.merge(c, d))
      assert Merge.merge(Merge.merge(a, d), c) == Merge.merge(Merge.merge(c, a), d)

      # everything survives the encoding used for sync
      assert {:ok, ^m} = VaultDoc.decode(VaultDoc.encode(m))
    end
  end

  for seed <- 1..40 do
    test "payments-only replicas: no payment lost or double applied (seed #{seed})" do
      :rand.seed(:exsss, {unquote(seed), 5, 1})

      b =
        Enum.reduce(1..2, VaultDoc.new(), fn i, d ->
          ok!(d, {:add_debt, card(%{name: "b#{i}", balance: 10_000_000})}, now: seconds(i))
        end)

      ids = VaultDoc.view(b).debts |> Enum.map(& &1.id)

      pay = fn doc, n ->
        Enum.reduce(1..n, doc, fn k, d ->
          ok!(
            d,
            {:log_payment, Enum.random(ids),
             %{amount: :rand.uniform(5_000), paid_on: "2026-11-02"}},
            now: seconds(:rand.uniform(100) + k)
          )
        end)
      end

      a = pay.(b, 6)
      c = pay.(b, 5)
      d = pay.(b, 4)
      # partial syncs in a random pattern
      ac = Merge.merge(a, c)
      c2 = pay.(ac, 3)
      all = [a, c, d] |> Enum.shuffle() |> Enum.reduce(&Merge.merge/2) |> Merge.merge(c2)

      view = VaultDoc.view(all)
      assert length(view.payments) == 6 + 5 + 4 + 3

      for debt <- view.debts do
        spent =
          view.payments
          |> Enum.filter(&(&1.debt_id == debt.id))
          |> Enum.map(& &1.principal_portion)
          |> Enum.sum()

        assert debt.balance == 10_000_000 - spent
      end
    end
  end
end

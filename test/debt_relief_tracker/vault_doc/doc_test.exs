defmodule DebtReliefTracker.VaultDoc.DocTest do
  use DebtReliefTracker.DataCase

  import DebtReliefTracker.VaultDocHelpers

  alias DebtReliefTracker.{Accounts, Storage.Plain, VaultDoc}
  alias DebtReliefTracker.VaultDoc.{Json, Ledger, Stamp}

  describe "Stamp" do
    test "normalises forms and orders chronologically" do
      assert {:ok, "2026-11-01T12:00:00.000000Z"} = Stamp.normalize("2026-11-01T12:00:00Z")
      assert {:ok, "2026-11-01T12:00:00.120000Z"} = Stamp.normalize("2026-11-01T12:00:00.12Z")
      assert {:ok, "2026-11-01T12:00:00.123456Z"} = Stamp.normalize("2026-11-01T12:00:00.1234567")
      assert {:ok, "2026-11-01T12:00:00.000000Z"} = Stamp.normalize("2026-11-01T12:00:00")
      for bad <- ["", "2026-11-01", "2026-13-01T00:00:00Z", "2026-02-30T00:00:00Z", "1969-12-31T00:00:00Z", "2026-11-01T24:00:00Z", nil, 5],
          do: assert(Stamp.normalize(bad) == :error)
    end

    test "bump carries across seconds, days, months and years" do
      assert Stamp.bump("2026-11-01T12:00:00.000000Z") == "2026-11-01T12:00:00.000001Z"
      assert Stamp.bump("2026-11-01T12:00:00.999999Z") == "2026-11-01T12:00:01.000000Z"
      assert Stamp.bump("2026-11-01T23:59:59.999999Z") == "2026-11-02T00:00:00.000000Z"
      assert Stamp.bump("2026-11-30T23:59:59.999999Z") == "2026-12-01T00:00:00.000000Z"
      assert Stamp.bump("2024-02-28T23:59:59.999999Z") == "2024-02-29T00:00:00.000000Z"
      assert Stamp.bump("2026-12-31T23:59:59.999999Z") == "2027-01-01T00:00:00.000000Z"
      assert Stamp.after_("2026-01-01T00:00:00.000000Z", "2026-01-01T00:00:00.000000Z") == "2026-01-01T00:00:00.000001Z"
    end

    test "matches DateTime for random instants" do
      :rand.seed(:exsss, {1, 1, 1})

      for _ <- 1..200 do
        dt = DateTime.from_unix!(:rand.uniform(4_000_000_000), :second) |> DateTime.add(:rand.uniform(999_999), :microsecond)
        {:ok, s} = Stamp.normalize(DateTime.to_iso8601(%{dt | microsecond: {elem(dt.microsecond, 0), 6}}))
        assert s == DateTime.to_iso8601(%{dt | microsecond: {elem(dt.microsecond, 0), 6}})
        next = DateTime.add(dt, 1, :microsecond)
        assert Stamp.bump(s) == DateTime.to_iso8601(%{next | microsecond: {elem(next.microsecond, 0), 6}})
      end
    end
  end

  describe "new / view / encode / decode" do
    test "an empty document round-trips and views as an empty snapshot" do
      doc = VaultDoc.new()
      assert {:ok, ^doc} = VaultDoc.decode(VaultDoc.encode(doc))
      view = VaultDoc.view(doc)
      assert %{debts: [], payments: [], activity: [], retirement_profiles: [], schema_version: 1} = view
      assert view.settings.currency == "USD"
    end

    test "decode rejects malformed documents without raising" do
      good = VaultDoc.new() |> ok!({:add_debt, card()})
      text = VaultDoc.encode(good)
      assert {:ok, _} = VaultDoc.decode(text)
      {:ok, raw} = Json.decode(text)
      [{id, debt}] = Map.to_list(raw["debts"])

      broken = [
        "",
        "null",
        "[]",
        "{}",
        Json.encode(%{raw | "schema_version" => 2}),
        Json.encode(Map.delete(raw, "debts")),
        Json.encode(%{raw | "debts" => %{"other" => debt}}),
        Json.encode(%{raw | "debts" => %{id => %{debt | "balance" => "5"}}}),
        Json.encode(%{raw | "debts" => %{id => %{debt | "type" => "weird"}}}),
        Json.encode(%{raw | "debts" => %{id => Map.delete(debt, "name")}}),
        Json.encode(%{raw | "debts" => %{id => %{debt | "updated_at" => "yesterday"}}}),
        Json.encode(%{raw | "debts" => %{id => %{debt | "applied" => %{"x" => "y"}}}}),
        Json.encode(%{raw | "settings" => %{raw["settings"] | "budget_mode" => "weekly"}}),
        Json.encode(%{raw | "settings_updated_at" => %{}}),
        Json.encode(%{raw | "activity" => 5})
      ]

      for text <- broken, do: assert({text, {:error, :invalid}} == {text, VaultDoc.decode(text)})
      assert {:error, :invalid} = VaultDoc.decode(nil)
    end

    test "unknown keys are dropped on decode" do
      {:ok, raw} = Json.decode(VaultDoc.encode(VaultDoc.new()))
      assert {:ok, doc} = VaultDoc.decode(Json.encode(Map.put(raw, "future", 1)))
      assert doc == VaultDoc.new()
    end

    test "tricky strings survive encode/decode of a real document" do
      doc =
        VaultDoc.new()
        |> ok!({:add_debt, card(%{name: "Zoë \"Q\"\n😀\\ " <> String.duplicate("x", 60)})})
        |> ok!({:update_settings, %{currency: "€\t"}})

      assert {:ok, ^doc} = VaultDoc.decode(VaultDoc.encode(doc))
    end

    test "a ~1 MB document encodes and decodes" do
      doc =
        base = VaultDoc.new() |> ok!({:add_debt, card()})
      id = debt_id(base, "Visa")

      Enum.reduce(1..400, base, fn i, d ->
          ok!(d, {:update_debt, id, %{name: "Visa #{i}"}}, now: seconds(i))
        end)

      text = VaultDoc.encode(doc)
      assert {:ok, ^doc} = VaultDoc.decode(text)
    end
  end

  describe "from_snapshot" do
    test "builds a document whose view equals the snapshot (modulo stamps)" do
      owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
      ws = Accounts.current_workspace_for_user(owner)
      {:ok, _} = Plain.apply_change(ws, owner, {:add_debt, card(%{position: 1})})
      {:ok, _} = Plain.apply_change(ws, owner, {:add_debt, loan(%{position: 0})})
      {:ok, s} = Plain.load(ws)
      id = hd(s.debts).id

      {:ok, _} = Plain.apply_change(ws, owner, {:log_payment, id, %{amount: 500, paid_on: "2026-11-01", note: "x"}})
      {:ok, _} = Plain.apply_change(ws, owner, {:update_settings, %{monthly_budget: 5}})
      {:ok, snapshot} = Plain.load(ws)

      doc = VaultDoc.from_snapshot(snapshot, "2026-11-01T00:00:00Z")
      view = VaultDoc.view(doc)
      assert view.debts == snapshot.debts
      assert view.payments == snapshot.payments
      assert view.activity == snapshot.activity
      assert Map.delete(view.settings, :updated_at) == Map.delete(snapshot.settings, :updated_at)
      assert view.retirement_profiles == snapshot.retirement_profiles
      assert Enum.all?(Map.values(doc.debts), &(not &1.deleted))
      # the payment is already reflected in the balance: merging with itself changes nothing
      assert DebtReliefTracker.VaultDoc.Merge.merge(doc, doc) == doc
      assert {:ok, ^doc} = VaultDoc.decode(VaultDoc.encode(doc))
    end

    test "stamps missing timestamps with now" do
      snap = %{
        schema_version: 1,
        settings: %{monthly_budget: nil, currency: "USD", budget_mode: "total", retirement_onboarding_dismissed: false},
        debts: [%{id: "d1", name: "x", type: "installment", status: "active", balance: 1, original_balance: nil, apr_bp: 0, fixed_payment: 1, minimum_payment_floor: nil, minimum_payment_rate_bp: nil, credit_limit: nil, exclude_from_plan: false, statement_balance: nil, statement_date: nil, position: 0, due_day: nil, auto_log_mode: "off", last_due_handled_on: nil, paid_off_at: nil}],
        payments: [],
        activity: [],
        retirement_profiles: []
      }

      doc = VaultDoc.from_snapshot(snap, "2026-11-01T00:00:00Z")
      assert doc.debts["d1"].updated_at == "2026-11-01T00:00:00.000000Z"
      assert doc.settings_updated_at.currency == "2026-11-01T00:00:00.000000Z"
    end
  end

  describe "Ledger contract" do
    test "bad ctx or unknown changes never raise" do
      doc = VaultDoc.new()
      good = ctx()

      for bad <- [nil, %{}, %{good | now: "x"}, %{good | today: "2026-02-30"}, %{good | new_id: 5}] do
        assert {:error, {:invalid, %{ctx: _}}} = Ledger.apply_change(doc, {:add_debt, card()}, bad)
      end

      assert {:error, {:invalid, _}} = Ledger.apply_change(doc, :nope, good)
      assert {:error, {:invalid, _}} = Ledger.apply_change(doc, {:add_debt, card()}, %{good | new_id: fn -> raise "boom" end})
    end

    test "fuzz: random garbage changes never raise and leave the doc untouched" do
      :rand.seed(:exsss, {4, 4, 4})
      doc = VaultDoc.new() |> ok!({:add_debt, card()})
      id = debt_id(doc, "Visa")
      junk = [nil, 1, -1, "x", "", :a, %{}, %{a: 1}, [], [1], {}, {1}, 1.5, %{amount: "x", paid_on: 3}, %{name: <<255>>}]

      for _ <- 1..400 do
        change =
          Enum.random([
            {:add_debt, Enum.random(junk)},
            {:update_debt, Enum.random([id, Enum.random(junk)]), Enum.random(junk)},
            {:log_payment, Enum.random([id, Enum.random(junk)]), Enum.random(junk)},
            {:reconcile_balance, Enum.random([id, Enum.random(junk)]), Enum.random(junk)},
            {:handle_due, Enum.random([id, Enum.random(junk)]), Enum.random([:post, :skip, Enum.random(junk)]), Enum.random(junk)},
            {:update_settings, Enum.random(junk)},
            {:add_member_retirement_profile, Enum.random(junk), Enum.random(junk)},
            {:add_manual_retirement_profile, Enum.random(junk)},
            {:update_retirement_profile, Enum.random(junk), Enum.random(junk)},
            {:delete_retirement_profile, Enum.random(junk)},
            {:mark_paid_off, Enum.random(junk)},
            {:delete_debt, Enum.random(junk)},
            Enum.random(junk)
          ])

        assert match?({:error, _}, Ledger.apply_change(doc, change, ctx())) or
                 match?({:ok, _}, Ledger.apply_change(doc, change, ctx()))
      end
    end
  end

  describe "ordering and stamps" do
    test "same-second edits get strictly increasing updated_at" do
      doc = VaultDoc.new() |> ok!({:add_debt, card()}, now: seconds(0))
      id = debt_id(doc, "Visa")
      a = ok!(doc, {:update_debt, id, %{name: "A"}}, now: seconds(0))
      b = ok!(a, {:update_debt, id, %{name: "B"}}, now: seconds(0))
      assert doc.debts[id].updated_at < a.debts[id].updated_at
      assert a.debts[id].updated_at < b.debts[id].updated_at
    end

    test "activity of one change is ordered newest first like insertion order" do
      doc = VaultDoc.new() |> ok!({:add_debt, card(%{statement_balance: 1, statement_date: "2026-10-01"})})
      id = debt_id(doc, "Visa")
      doc = ok!(doc, {:reconcile_balance, id, 50_000})
      assert Enum.map(VaultDoc.view(doc).activity, & &1.action) == ["debt_updated", "payment_logged", "debt_added"]
    end

    test "a no-op update keeps updated_at but still logs activity" do
      doc = VaultDoc.new() |> ok!({:add_debt, card()}, now: seconds(0))
      id = debt_id(doc, "Visa")
      again = ok!(doc, {:update_debt, id, %{name: "Visa"}}, now: seconds(50))
      assert again.debts[id].updated_at == doc.debts[id].updated_at
      assert map_size(again.activity) == 2
    end
  end

  describe "catch_up and deterministic ids" do
    test "posts missed cycles for automatic debts, reports confirm debts, is idempotent" do
      doc =
        VaultDoc.new()
        |> ok!({:add_debt, loan(%{name: "Auto", auto_log_mode: "automatic", due_day: 5, last_due_handled_on: "2026-08-05", balance: 100_000})})
        |> ok!({:add_debt, loan(%{name: "Confirm", auto_log_mode: "confirm", due_day: 7})})
        |> ok!({:add_debt, loan(%{name: "Off"})})
        |> ok!({:add_debt, card()})

      {:ok, d1, r} = Ledger.catch_up(doc, ctx(today: "2026-11-10", now: seconds(100)))
      auto = debt_id(doc, "Auto")

      assert Enum.map(r.posted, & &1.cycle) == ["2026-09-05", "2026-10-05", "2026-11-05"]
      assert Enum.map(r.posted, & &1.payment_id) == for(c <- ["2026-09-05", "2026-10-05", "2026-11-05"], do: "#{auto}:#{c}")
      assert [%{cycles: ["2026-11-07"]}] = r.pending_confirm
      assert r.failed == [] and r.stamped == []
      view = VaultDoc.view(d1)
      assert Enum.find(view.debts, &(&1.name == "Auto")).balance == 70_000
      assert Enum.find(view.debts, &(&1.name == "Auto")).last_due_handled_on == "2026-11-05"
      assert length(view.payments) == 3
      assert Enum.count(view.activity, &(&1.action == "payment_auto_logged")) == 3
      assert Enum.all?(view.activity, &(&1.user_id == nil))

      {:ok, d2, r2} = Ledger.catch_up(d1, ctx(today: "2026-11-10", now: seconds(200)))
      assert d2.debts == d1.debts and d2.payments == d1.payments and d2.activity == d1.activity
      assert r2.posted == []
    end

    test "a payment larger than the balance is reported failed and not stamped" do
      doc = VaultDoc.new() |> ok!({:add_debt, loan(%{auto_log_mode: "automatic", due_day: 5, balance: 100})})
      {:ok, d, r} = Ledger.catch_up(doc, ctx(today: "2026-11-10"))
      assert [%{cycle: "2026-11-05", error: {:invalid, %{balance: _}}}] = r.failed
      assert d.debts == doc.debts
    end

    test "handle_due post with a deterministic id; posting twice is not_due; stamped when payment exists" do
      doc = VaultDoc.new() |> ok!({:add_debt, loan(%{auto_log_mode: "confirm", due_day: 5})})
      id = debt_id(doc, "Loan")
      d = ok!(doc, {:handle_due, id, :post, "2026-11-05"}, today: "2026-11-10", actor: "u1")
      assert Map.has_key?(d.payments, "#{id}:2026-11-05")
      assert d.activity["#{id}:2026-11-05:logged"].action == "payment_logged"
      assert {:error, :not_due} = Ledger.apply_change(d, {:handle_due, id, :post, "2026-11-05"}, ctx(today: "2026-11-10"))
      assert {:error, :not_due} = Ledger.apply_change(doc, {:handle_due, id, :post, "2026-11-06"}, ctx(today: "2026-11-10"))
      assert {:error, :not_due} = Ledger.apply_change(doc, {:handle_due, id, :post, "2026-12-05"}, ctx(today: "2026-11-10"))

      # payment known (from a merge) but the cycle not stamped here: only stamps
      stale = %{d | debts: Map.put(d.debts, id, %{d.debts[id] | last_due_handled_on: nil})}
      again = ok!(stale, {:handle_due, id, :post, "2026-11-05"}, today: "2026-11-10")
      assert again.debts[id].last_due_handled_on == "2026-11-05"
      assert again.payments == d.payments and again.debts[id].balance == d.debts[id].balance
    end
  end
end

defmodule DebtReliefTracker.VaultDocScript do
  @moduledoc """
  A fixed, pure change script over `VaultDoc`, used to prove the *compiled*
  (browser) ledger behaves exactly like the server one: `run/1` returns one
  JSON string (`VaultDoc.Json.encode/1` of every step's view, error, the
  merged document and some JSON round-trips). ExUnit computes it on the BEAM;
  `BrowserCase.VaultDocPage` computes it in Chromium via Hologram; the browser
  test asserts the two strings are byte-identical.

  Client-safe on purpose (this module is compiled to JavaScript).
  """

  alias DebtReliefTracker.VaultDoc
  alias DebtReliefTracker.VaultDoc.{Json, Ledger, Merge}

  @doc "Tricky JSON data (unicode, escapes, big ints, deep maps)."
  def tricky do
    %{
      "unicode" => "Zoë's Kreditkarte – 日本語 😀 é",
      "quotes" => "she said \"hi\" and \\ left",
      "controls" => "line1\nline2\r\n\ttab\u0000nul\u001f\u007f",
      "sixty" => String.duplicate("N", 60),
      "empty" => "",
      "nil" => nil,
      "bools" => [true, false],
      "big" => 999_999_999_999_999,
      "neg" => -999_999_999_999_999,
      "zero" => 0,
      "list" => [1, [2, [3, []]], %{}],
      "deep" => %{"a" => %{"b" => %{"c" => %{"d" => [%{"e" => "x\"y"}]}}}},
      "ключ" => "значение"
    }
  end

  @doc "Runs the script. `new_id` is a 0-arity id source (same sequence on both sides)."
  def run(new_id) do
    base = VaultDoc.new()

    {doc, steps} =
      Enum.reduce(script(), {base, []}, fn {n, fun}, {doc, steps} ->
        change = fun.(doc)
        {doc, step} = apply_step(doc, change, n, new_id)
        {doc, [step | steps]}
      end)

    # two diverged replicas of `doc`, then merged
    a = branch(doc, new_id, 100, "a")
    b = branch(doc, new_id, 200, "b")
    merged = Merge.merge(a, b)

    {:ok, caught, report} = Ledger.catch_up(merged, ctx(300, "2026-12-20", new_id))
    tricky = tricky()

    Json.encode(%{
      "steps" => Enum.reverse(steps),
      "merged" => VaultDoc.encode(merged),
      "merge_commutes" => merged == Merge.merge(b, a),
      "merged_view" => Json.encode(VaultDoc.view(merged)),
      "caught_up" => VaultDoc.encode(caught),
      "report" => Json.encode(report),
      "roundtrip" => VaultDoc.decode(VaultDoc.encode(merged)) == {:ok, merged},
      "tricky" => Json.encode(tricky),
      "tricky_roundtrip" => Json.decode(Json.encode(tricky)) == {:ok, tricky},
      "bad_json" => [
        Json.decode("{\"a\":1.5}"),
        Json.decode("[1,]"),
        Json.decode("\"\\ud800\""),
        Json.decode("{\"a\":1,\"a\":2}")
      ]
      |> Enum.map(&(&1 == {:error, :invalid}))
    })
  end

  def ctx(n, today, new_id) do
    %{
      now: "2026-11-01T12:" <> pad(div(n, 60)) <> ":" <> pad(rem(n, 60)) <> "Z",
      today: today,
      new_id: new_id,
      actor: nil,
      members: nil
    }
  end

  defp pad(n), do: if(n < 10, do: "0" <> Integer.to_string(n), else: Integer.to_string(n))

  defp apply_step(doc, change, n, new_id) do
    case Ledger.apply_change(doc, change, ctx(n, "2026-11-10", new_id)) do
      {:ok, new} -> {new, Json.encode(VaultDoc.view(new))}
      {:error, error} -> {doc, "error:" <> Json.encode(error_term(error))}
    end
  end

  defp error_term({:invalid, errors}), do: %{"invalid" => errors}
  defp error_term(atom), do: Atom.to_string(atom)

  def branch(doc, new_id, offset, tag) do
    visa = id(doc, "Visa Gold")
    loan = id(doc, "Auto 日本")

    {:ok, d} =
      Ledger.apply_change(
        doc,
        {:log_payment, visa, %{amount: 1_000 + offset, paid_on: "2026-11-0" <> Integer.to_string(div(offset, 100) + 2)}},
        ctx(offset + 1, "2026-11-10", new_id)
      )

    {:ok, d} = Ledger.apply_change(d, {:update_debt, loan, %{name: "Auto " <> tag}}, ctx(offset + 2, "2026-11-10", new_id))
    {:ok, d} = Ledger.apply_change(d, {:update_settings, %{monthly_budget: offset}}, ctx(offset + 3, "2026-11-10", new_id))
    d
  end

  defp id(doc, name) do
    doc |> VaultDoc.view() |> Map.fetch!(:debts) |> Enum.find(&(&1.name == name)) |> Map.fetch!(:id)
  end

  def script do
    [
      {1, fn _ -> {:update_settings, %{monthly_budget: 250_000, currency: "EUR"}} end},
      {2, fn _ -> {:add_debt, %{name: "Visa \"Gold\" 😀", type: "revolving", balance: 450_000, apr_bp: 2499, minimum_payment_floor: 3500, minimum_payment_rate_bp: 200, credit_limit: 1_000_000, statement_balance: 450_000, statement_date: "2026-10-01"}} end},
      {3, fn _ -> {:add_debt, %{name: "Auto 日本", type: "installment", balance: 1_200_000, apr_bp: 650, fixed_payment: 35_000, auto_log_mode: "confirm", due_day: 5}} end},
      {4, fn _ -> {:add_debt, %{name: String.duplicate("L", 60), type: "installment", balance: 999_999_999_999, apr_bp: 0, fixed_payment: 100, auto_log_mode: "automatic", due_day: 31, last_due_handled_on: "2026-08-31"}} end},
      {5, fn _ -> {:add_debt, %{name: "", type: "revolving", balance: -1}} end},
      {6, fn doc -> {:update_debt, id(doc, "Visa \"Gold\" 😀"), %{name: "Visa Gold", position: 2}} end},
      {7, fn doc -> {:log_payment, id(doc, "Visa Gold"), %{amount: 10_000, interest_portion: 3_000, principal_portion: 7_000, paid_on: "2026-10-30", note: "wk 1 – ünï\n\"q\""}} end},
      {8, fn doc -> {:log_payment, id(doc, "Visa Gold"), %{amount: 99_999_999, paid_on: "2026-10-30"}} end},
      {9, fn doc -> {:log_payment, id(doc, "Auto 日本"), %{amount: 35_000, paid_on: "2026-11-05"}} end},
      {10, fn doc -> {:reconcile_balance, id(doc, "Visa Gold"), 430_000} end},
      {11, fn doc -> {:reconcile_balance, id(doc, "Auto 日本"), 1_300_000} end},
      {12, fn doc -> {:handle_due, id(doc, "Auto 日本"), :post, "2026-11-05"} end},
      {13, fn doc -> {:handle_due, id(doc, "Auto 日本"), :skip, "2026-11-05"} end},
      {14, fn _ -> {:add_manual_retirement_profile, %{name: "Sam 😀", claim_email: "sam@example.com", current_age: 30, retirement_age: 65, current_retirement_savings: 1_000_050, monthly_retirement_contribution: 10_000, monthly_gross_income: 500_000, post_debt_investment_bp: 1500, expected_annual_return_bp: 750}} end},
      {15, fn _ -> {:add_manual_retirement_profile, %{name: "Dup", claim_email: "sam@example.com", current_age: 30, retirement_age: 25, current_retirement_savings: 0, monthly_retirement_contribution: 0, monthly_gross_income: 0, post_debt_investment_bp: 1500, expected_annual_return_bp: 750}} end},
      {16, fn _ -> {:update_settings, %{retirement_onboarding_dismissed: true}} end},
      {17, fn doc -> {:mark_paid_off, id(doc, String.duplicate("L", 60))} end},
      {18, fn _ -> {:delete_debt, "missing"} end},
      {19, fn doc -> {:delete_debt, id(doc, String.duplicate("L", 60))} end},
      {20, fn _ -> {:nonsense, 1} end}
    ]
  end
end

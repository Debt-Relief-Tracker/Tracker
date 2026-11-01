defmodule DebtReliefTrackerWeb.Holo.E2EELockedTest do
  # Not async: E2EE / OIDC config is global.
  use DebtReliefTrackerWeb.ConnCase

  import DebtReliefTracker.E2EEHelpers

  alias DebtReliefTracker.{Accounts, Debts}
  alias DebtReliefTracker.E2EE.Vaults

  @marker "ZQXMARKERDEBT"
  @balance_cents "7,654.32"

  setup do
    workspace = Accounts.ensure_default_workspace!()

    {:ok, _} =
      Debts.create_debt(workspace, nil, %{
        "name" => @marker,
        "type" => "revolving",
        "balance" => "7654.32",
        "apr" => "24.99",
        "minimum_payment_floor" => "35.00",
        "minimum_payment_rate" => "0.02",
        "credit_limit" => "9000.00"
      })

    %{workspace: workspace}
  end

  defp doc(conn), do: conn |> get("/app") |> html_response(200) |> LazyHTML.from_document()
  defp count(doc, sel), do: doc |> LazyHTML.query(sel) |> Enum.count()

  describe "GET /app with E2EE on" do
    setup do
      enable_e2ee()
      :ok
    end

    test "renders the locked shell with no vault yet", %{conn: conn} do
      doc = doc(conn)
      assert count(doc, "#holo-dashboard") == 1
      assert count(doc, "#e2ee-locked") == 1
      assert count(doc, "#vault-gate") == 1
      assert doc |> LazyHTML.query("#e2ee-locked-status") |> LazyHTML.text() =~ "no vault"
    end

    test "says the vault is locked once one exists", %{conn: conn, workspace: ws} do
      {:ok, _} = Vaults.create(ws, "blob", passphrase_wrap())
      status = conn |> doc() |> LazyHTML.query("#e2ee-locked-status") |> LazyHTML.text()
      assert status =~ "locked"
      refute status =~ "no vault"
    end

    test "no vault: the setup wizard is offered, not the unlock screen", %{conn: conn} do
      doc = doc(conn)
      assert count(doc, "#vault-setup") == 1
      assert count(doc, "#setup-method-passphrase") == 1
      assert count(doc, "#setup-passphrase") == 1
      assert count(doc, "#vault-unlock") == 0
      assert count(doc, "#vault-home") == 0
    end

    test "with a vault: one unlock section per enrolled kind, never the wizard",
         %{conn: conn, workspace: ws} do
      {:ok, _} = Vaults.create(ws, "blob", passphrase_wrap())
      doc = doc(conn)
      assert count(doc, "#vault-unlock") == 1
      assert count(doc, "#unlock-passphrase-form") == 1
      assert count(doc, "#unlock-recovery-form") == 0
      assert count(doc, "#unlock-passkey-btn") == 0
      assert count(doc, "#vault-setup") == 0

      {:ok, _} = Vaults.add_key_wrap(ws, passkey_wrap())
      {:ok, _} = Vaults.add_key_wrap(ws, passphrase_wrap(%{kind: "recovery", label: "r"}))
      doc = doc(conn)
      assert count(doc, "#unlock-passkey-btn") == 1
      assert count(doc, "#unlock-recovery-form") == 1
      # the remembered-device button needs client-side detection: absent from the server render
      assert count(doc, "#unlock-device-btn") == 0
    end

    test "the vault blob is never rendered into the page", %{conn: conn, workspace: ws} do
      {:ok, _} = Vaults.create(ws, "v1.BLOBMARKERBLOB.BLOBMARKERBLOB", passphrase_wrap())
      body = conn |> get("/app") |> html_response(200)
      refute body =~ "BLOBMARKERBLOB"
      refute body =~ @marker
    end

    test "contains no plaintext financial data anywhere in the body", %{conn: conn} do
      body = conn |> get("/app") |> html_response(200)

      refute body =~ @marker
      refute body =~ @balance_cents
      refute body =~ "7654"
      refute body =~ "7,654"
      refute body =~ "24.99"
      refute body =~ "this-month-card"
      refute body =~ "debt-sidebar"
      # no snapshot in the serialized page state either
      refute body =~ "snapshot_updated"
    end

    test "the plaintext dashboard components are absent", %{conn: conn} do
      doc = doc(conn)

      for sel <- ["#this-month-card", "#summary-stats", "#budget-input", "#app-header"],
          do: assert(count(doc, sel) == 0, "unexpected #{sel}")
    end

    test "GET / redirects to /app instead of decrypting legacy plaintext", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == "/app"
      refute conn.resp_body =~ @marker
    end

    test "CSV exports are gone and say why", %{conn: conn} do
      for path <- ["/export/debts.csv", "/export/payments.csv"] do
        conn = get(conn, path)
        assert response(conn, 410) =~ "browser"
        refute conn.resp_body =~ @marker
      end
    end

    test "/admin still routes (unchanged)", %{conn: conn} do
      # no OIDC => admin scope resolves; the point is it does not redirect to /app
      conn = get(conn, ~p"/admin")
      refute conn.status in [301, 302] and redirected_to(conn) == "/app"
    end
  end

  describe "with E2EE off" do
    test "GET /app still renders the plaintext dashboard", %{conn: conn} do
      doc = doc(conn)
      assert count(doc, "#e2ee-locked") == 0
      assert doc |> LazyHTML.query("#this-month-card") |> LazyHTML.text() =~ @marker
    end

    test "GET / is the LiveView, exports work", %{conn: conn} do
      assert html_response(get(conn, ~p"/"), 200) =~ @marker
      assert response(get(conn, "/export/debts.csv"), 200) =~ @marker
    end
  end
end

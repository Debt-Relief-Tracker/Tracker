defmodule DebtReliefTrackerWeb.Holo.Components.AccountComponentsTest do
  # Not async: OIDC config is global.
  use DebtReliefTrackerWeb.ConnCase

  alias DebtReliefTracker.{Accounts, Settings}
  alias DebtReliefTrackerWeb.Holo.Components.{ActivityLogModal, HeaderBar, SettingsModal}
  alias DebtReliefTrackerWeb.Holo.Csrf
  alias Hologram.Component
  alias Hologram.Component.Action
  alias Hologram.Component.Command
  alias Hologram.Server

  defp enable_oidc do
    Application.put_env(:debt_relief_tracker, :oidc,
      issuer: "https://idp.example.com",
      client_id: "test-client",
      client_secret: "test-secret"
    )

    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:debt_relief_tracker, :oidc, nil)
      Application.delete_env(:swoosh, :shared_test_process)
    end)
  end

  defp oidc_user(sub, name) do
    Accounts.get_or_create_user_from_oidc!(%{
      "sub" => sub,
      "email" => "#{sub}@example.com",
      "name" => name
    })
  end

  # An empty workspace currently crashes PlanPanel's Summary.this_month/2
  # (foundation bug, not this feature), so GET /app tests need a debt.
  defp add_debt(workspace) do
    {:ok, _} =
      DebtReliefTracker.Debts.create_debt(workspace, nil, %{
        "name" => "Visa",
        "type" => "revolving",
        "balance" => "4500.00",
        "apr" => "24.99",
        "minimum_payment_floor" => "35.00",
        "minimum_payment_rate" => "0.02"
      })
  end

  defp server_for(user), do: %Server{stash: %{holo_user_id: user && user.id}}

  describe "GET /app" do
    setup do
      add_debt(Accounts.ensure_default_workspace!())
      :ok
    end

    test "renders the header with the ids the tutorial targets", %{conn: conn} do
      doc = conn |> get("/app") |> html_response(200) |> LazyHTML.from_document()

      assert LazyHTML.query(doc, "#app-header") |> Enum.count() == 1
      assert LazyHTML.query(doc, "#settings-button") |> Enum.count() == 1
      assert LazyHTML.query(doc, "#theme-toggle button") |> Enum.count() == 3
      assert LazyHTML.query(doc, "#workspace-name") |> LazyHTML.text() =~ "Debts"
      assert LazyHTML.query(doc, "#app-header[data-saved-theme=system]") |> Enum.count() == 1
    end

    test "no-auth mode shows neither the user menu nor the workspace switcher", %{conn: conn} do
      doc = conn |> get("/app") |> html_response(200) |> LazyHTML.from_document()

      assert LazyHTML.query(doc, "#user-menu") |> Enum.count() == 0
      assert LazyHTML.query(doc, "#workspace-switcher") |> Enum.count() == 0
    end

    test "loads the theme facade script, not app.js, and no inline script of ours", %{conn: conn} do
      doc = conn |> get("/app") |> html_response(200) |> LazyHTML.from_document()

      assert LazyHTML.query(doc, ~s(script[src="/assets/js/holo_account.js"])) |> Enum.count() ==
               1

      assert LazyHTML.query(doc, ~s(script[src="/assets/js/app.js"])) |> Enum.count() == 0
    end

    test "OIDC mode shows the display name and log out for a signed-in user", %{conn: conn} do
      enable_oidc()
      user = oidc_user("a", "Alex")
      add_debt(Accounts.current_workspace_for_user(user))

      doc =
        conn
        |> Plug.Test.init_test_session(user_id: user.id)
        |> get("/app")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert LazyHTML.query(doc, "#user-display-name") |> LazyHTML.text() =~ "Alex"
      assert LazyHTML.query(doc, "#logout-button") |> Enum.count() == 1
    end

    test "OIDC mode shows the workspace switcher once the user has two workspaces", %{conn: conn} do
      enable_oidc()
      owner = oidc_user("owner", "Owner")
      member = oidc_user("member", "Member")
      owner_workspace = Accounts.current_workspace_for_user(owner)
      {:ok, _} = Accounts.share_workspace_with_email(owner_workspace, "member@example.com", owner)
      add_debt(Accounts.current_workspace_for_user(member))

      doc =
        conn
        |> Plug.Test.init_test_session(user_id: member.id)
        |> get("/app")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert LazyHTML.query(doc, "#workspace-switcher option") |> Enum.count() == 2
    end

    test "a workspace chosen via the switcher is the one the next request uses", %{conn: conn} do
      enable_oidc()
      owner = oidc_user("owner", "Owner")
      member = oidc_user("member", "Member")
      owner_workspace = Accounts.current_workspace_for_user(owner)
      {:ok, _} = Accounts.share_workspace_with_email(owner_workspace, "member@example.com", owner)
      add_debt(owner_workspace)

      conn =
        conn
        |> Plug.Test.init_test_session(user_id: member.id, workspace_id: owner_workspace.id)
        |> get("/app")

      doc = conn |> html_response(200) |> LazyHTML.from_document()
      assert LazyHTML.query(doc, "#workspace-name") |> LazyHTML.text() =~ "Owner"
    end
  end

  describe "HeaderBar" do
    test "open_settings opens the settings modal with its server-only data" do
      Accounts.ensure_default_workspace!()

      server = HeaderBar.command(:open_settings, %{}, server_for(nil))

      assert %Action{name: :open_modal, target: "page", params: %{modal: modal}} =
               server.next_action

      assert modal.type == :settings
      assert modal.is_owner
    end

    test "set_theme action applies locally and queues the save command" do
      component = HeaderBar.action(:set_theme, %{theme: "dark"}, %Component{})

      assert %Command{name: :save_theme, params: %{theme: "dark"}} = component.next_command
    end

    test "save_theme saves to the account and refreshes page account" do
      Accounts.ensure_default_workspace!()

      server = HeaderBar.command(:save_theme, %{theme: "light"}, server_for(nil))

      assert Accounts.get_default_user!().preferences.theme == :light

      assert %Action{name: :account_updated, target: "page", params: %{account: account}} =
               server.next_action

      assert account.user.theme == "light"
    end

    test "switch_workspace stores the choice and reloads snapshot + account" do
      enable_oidc()
      owner = oidc_user("owner", "Owner")
      member = oidc_user("member", "Member")
      owner_workspace = Accounts.current_workspace_for_user(owner)
      {:ok, _} = Accounts.share_workspace_with_email(owner_workspace, "member@example.com", owner)

      server =
        HeaderBar.command(
          :switch_workspace,
          %{workspace_id: owner_workspace.id},
          server_for(member)
        )

      assert Server.get_session(server, :workspace_id) == owner_workspace.id

      assert %Action{name: :account_changed, target: "page", params: params} = server.next_action
      assert params.account.workspace.id == owner_workspace.id
      assert params.modal == nil
      assert is_map(params.snapshot)
    end

    test "switch_workspace refuses a workspace the user doesn't belong to" do
      enable_oidc()
      member = oidc_user("member", "Member")
      other_workspace = Accounts.current_workspace_for_user(oidc_user("other", "Other"))

      server =
        HeaderBar.command(
          :switch_workspace,
          %{workspace_id: other_workspace.id},
          server_for(member)
        )

      assert server.next_action == nil
      assert Server.get_session(server, :workspace_id) == nil
    end

    test "logout mints a CSRF token that Plug validates against the session" do
      server = HeaderBar.command(:logout_token, %{}, server_for(nil))

      assert %Action{name: :submit_logout, params: %{token: token}} = server.next_action
      state = Server.get_session(server, "_csrf_token")
      assert Plug.CSRFProtection.valid_state_and_csrf_token?(state, token)
    end

    test "a session's existing CSRF state is reused" do
      {_token, first} = Csrf.issue(server_for(nil))
      state = Server.get_session(first, "_csrf_token")

      {token, second} = Csrf.issue(first)

      assert Server.get_session(second, "_csrf_token") == state
      assert Plug.CSRFProtection.valid_state_and_csrf_token?(state, token)
    end
  end

  describe "SettingsModal" do
    setup do
      workspace = Accounts.ensure_default_workspace!()
      {:ok, snapshot} = DebtReliefTracker.Storage.load(workspace)
      {:ok, workspace: workspace, snapshot: snapshot}
    end

    defp props(snapshot) do
      account = DebtReliefTrackerWeb.Holo.Context.account(server_for(nil))
      %{snapshot: snapshot, account: account}
    end

    test "init seeds the form from the account and snapshot", %{snapshot: snapshot} do
      component = SettingsModal.init(props(snapshot), %Component{})

      assert component.state.name_input == "You"
      assert component.state.currency_input == "USD"
      assert component.state.ws_name_input == props(snapshot).account.workspace.name
    end

    test "typing updates form state; Save sends all three fields in one command", %{
      snapshot: snapshot
    } do
      component =
        props(snapshot)
        |> SettingsModal.init(%Component{})
        |> then(&SettingsModal.action(:set_name, %{event: %{value: "Sam"}}, &1))
        |> then(&SettingsModal.action(:set_ws_name, %{event: %{value: "Sam's Plan"}}, &1))
        |> then(&SettingsModal.action(:set_currency, %{event: %{value: "GBP"}}, &1))
        |> then(&SettingsModal.action(:save, %{}, &1))

      assert %Command{
               name: :save_settings,
               params: %{display_name: "Sam", workspace_name: "Sam's Plan", currency: "GBP"}
             } = component.next_command
    end

    test "save_settings writes everything and closes the modal", %{
      workspace: workspace,
      snapshot: snapshot
    } do
      _ = snapshot

      server =
        SettingsModal.command(
          :save_settings,
          %{display_name: "Sam", workspace_name: "Sam's Plan", currency: "GBP"},
          server_for(nil)
        )

      assert %Action{name: :account_changed, target: "page", params: params} = server.next_action
      assert params.modal == nil
      assert params.account.user.display_name == "Sam"
      assert params.account.workspace.name == "Sam's Plan"
      assert params.snapshot.settings.currency == "GBP"
      assert Settings.get_settings!(workspace).currency == "GBP"
    end

    test "an invalid field blocks the whole save and reports it", %{workspace: workspace} do
      server =
        SettingsModal.command(
          :save_settings,
          %{display_name: "Sam", workspace_name: "", currency: "GBP"},
          server_for(nil)
        )

      assert %Action{name: :save_failed, params: %{errors: %{workspace_name: _}}} =
               server.next_action

      assert Accounts.get_default_user!().display_name == "You"
      assert Settings.get_settings!(workspace).currency == "USD"

      component =
        SettingsModal.action(:save_failed, server.next_action.params, %Component{})

      assert component.state.ws_name_error
      assert component.state.display_name_error == nil
    end

    test "sharing commands refresh the modal with a notice and the pending list" do
      enable_oidc()
      owner = oidc_user("owner", "Owner")
      server = server_for(owner)

      server = SettingsModal.command(:share_workspace, %{email: "new@example.com"}, server)

      assert %Action{name: :open_modal, target: "page", params: %{modal: modal}} =
               server.next_action

      assert modal.notice =~ "Invited new@example.com"
      assert [%{email: "new@example.com", id: id}] = modal.pending_invitations

      server = SettingsModal.command(:cancel_invitation, %{id: id}, server_for(owner))
      assert %Action{params: %{modal: %{pending_invitations: []}}} = server.next_action
    end

    test "sharing twice reports an error in the modal" do
      enable_oidc()
      owner = oidc_user("owner", "Owner")
      SettingsModal.command(:share_workspace, %{email: "new@example.com"}, server_for(owner))

      server =
        SettingsModal.command(:share_workspace, %{email: "new@example.com"}, server_for(owner))

      assert %Action{params: %{modal: %{error: "new@example.com has already been invited."}}} =
               server.next_action
    end

    test "remove_member drops the member from the refreshed modal" do
      enable_oidc()
      owner = oidc_user("owner", "Owner")
      _member = oidc_user("member", "Member")
      SettingsModal.command(:share_workspace, %{email: "member@example.com"}, server_for(owner))

      [%{id: row_id}] =
        Accounts.list_workspace_members(Accounts.current_workspace_for_user(owner))

      server = SettingsModal.command(:remove_member, %{id: row_id}, server_for(owner))

      assert %Action{params: %{modal: %{accepted_members: []}}} = server.next_action
    end

    test "share action clears the field and sends the typed email" do
      component =
        %Component{state: %{share_email: "a@example.com"}}
        |> then(&SettingsModal.action(:share, %{}, &1))

      assert component.state.share_email == ""

      assert %Command{name: :share_workspace, params: %{email: "a@example.com"}} =
               component.next_command
    end
  end

  describe "ActivityLogModal" do
    setup do
      Accounts.ensure_default_workspace!()
      :ok
    end

    test "opening it fetches actor names for the entries" do
      component = ActivityLogModal.init(%{}, %Component{})
      assert %Command{name: :load_actors} = component.next_command

      server = ActivityLogModal.command(:load_actors, %{}, server_for(nil))
      assert %Action{name: :actors_loaded, params: %{actors: actors}} = server.next_action
      assert "You" in Map.values(actors)

      component = ActivityLogModal.action(:actors_loaded, %{actors: actors}, component)
      assert component.state.actors == actors
    end
  end
end

# Cutover test coverage: DashboardLive tests -> Hologram `/app`

Maps every test in `test/debt_relief_tracker_web/live/dashboard_live_test.exs` and
`dashboard_live_oidc_test.exs` to its Hologram equivalent so DashboardLive can be
deleted without losing behavior coverage. Paths are under
`test/debt_relief_tracker_web/`. "NEW" = added in `holo/cutover_gaps_test.exs`.
`dual` = `holo/dual_mode_flows_browser_test.exs` (runs plaintext and E2EE).

## dashboard_live_test.exs

| LiveView test | Covered by |
|---|---|
| renders the seeded placeholder debts in the rail | holo/debt_sidebar_page_test.exs "GET /app renders the debt rail" |
| adding a debt shows up in the rail | holo/debt_flows_browser_test.exs "adds a revolving debt"; dual |
| adding first debt to empty workspace re-simulates (no stale $200 message) | holo/plan_panel_browser_test.exs "typing a budget with no debts does not crash or mislabel"; holo/plan_test.exs "no debts at all"; dashboard_page_test "a saved budget below the minimums is a budget message" |
| rejects add-debt missing type-specific required field | holo/components/debt_components_test.exs DebtFormModal "add: required type-specific fields are enforced"; debt_flows_browser "shows validation errors" |
| logging a payment reduces the balance | debt_flows_browser "logs a payment"; debt_components PaymentModal |
| marking a debt paid off shows it struck through | debt_flows_browser "marks a debt paid after an inline confirm"; holo/debt_logic_test.exs "paid off is struck through" |
| deleting a debt from the edit modal removes it | debt_flows_browser "deletes a debt after an inline confirm" |
| delete button only on edit modal | debt_components DebtFormModal "delete is only offered on edit" |
| debt excluded from plan greyed out | holo/debt_logic_test.exs "excluded debts are dimmed" |
| revolving with credit limit shows utilization | holo/debt_logic_test.exs "shows the balance, utilization and flags"; liveview_vs_holo_browser |
| revolving without credit limit shows no badge | holo/debt_logic_test.exs "no utilization without a credit limit" |
| overall credit utilization stat only with a limit | holo/dashboard_page_test.exs "summary stat cards ... utilization once a limit is set"; plan_test "no utilization without a credit limit" |
| CSV export links in settings modal | holo/csv_export_test.exs; dual "settings: CSV export is built in the browser"; controllers/export_controller_test.exs |
| activity log shows human-readable entries | holo/activity_test.exs; components/account_components_test.exs ActivityLogModal; dual "the activity log shows entries" |
| closing the activity log hides it | dual "modals close with Escape, outside click and Cancel"; debt_flows_browser "closing modals" |
| switching chart type pushes matching Chart.js config | holo/plan_panel_test.exs "switching chart type re-draws with the matching Chart.js type"; plan_chart_browser_test |
| donate modal: footer link + modal | holo/dashboard_page_test.exs "renders the footer with the donate modal"; tutorial_footer_browser "footer" |
| retirement: chart shows setup message w/o profile | retirement_browser "retirement roadmap chart: message without a profile"; plan_panel_test "the retirement roadmap shows its setup message" |
| retirement: fresh workspace shows banner | holo/retirement_modal_test.exs "banner shows for a fresh workspace"; retirement_browser "banner shows" |
| retirement: banner button opens roster first | retirement_browser "banner shows, opens the roster" |
| retirement: 'Add person' opens separate form modal, defaults to current member | retirement_modal_test "opening the add form loads members"; retirement_browser "member profile for the existing household member" |
| retirement: adding a profile returns to roster, hides banner, renders chart | retirement_modal_test "submitting a member profile saves it and returns to the roster"; retirement_browser "manual profile ..." |
| retirement: second person with no account | retirement_modal_test "can add a second person with no account of their own" |
| retirement: rejects retirement age not after current age | retirement_modal_test "rejects a retirement age ..."; retirement_form_test "rejects a retirement age" |
| retirement: cancel returns to roster | retirement_modal_test "canceling the form returns to the roster" |
| retirement: dismissing banner persists | retirement_modal_test "dismissing persists the flag"; retirement_browser "dismissing the banner persists across reload" |
| retirement: skip from roster dismisses banner | retirement_modal_test "skip for now"; retirement_browser "Skip for now" |
| retirement: edit from Settings pre-fills | retirement_modal_test "edit pre-fills the form"; retirement_form_test "from_profile/1" |
| retirement: saving edited profile updates roster | retirement_modal_test "edit pre-fills the form; update saves"; retirement_browser "edit a profile, then remove it" |
| switching strategy re-simulates | plan_panel_test "a new strategy (via the page) re-plans"; plan_panel_browser "strategy switcher"; dual "strategy switcher and every chart type" |
| updating monthly budget re-simulates this-month card | plan_panel_test "budget"; plan_panel_browser "total mode: typing a budget re-plans and persists" |
| budget input step allows cents | dashboard_page_test "budget input (cents step)" |
| summary stat cards in order | dashboard_page_test "summary stat cards in order" |
| total/interest paid project remaining plan | plan_test "total paid = debt remaining + projected interest" |
| payoff date box shows months remaining | plan_test "... with payoff date and months"; "month_label/2" |
| toggling budget mode to margin | plan_panel_test "switching budget mode"; plan_panel_browser "margin mode"; dual "budget margin mode" |
| selecting a currency persists + re-renders symbol | account_ops_test "one Save writes name, tracker name, and currency"; dual "very long names and the non-USD currency render"; NEW "a switched-to workspace renders in its own currency" (SSR symbol) |
| renaming tracker updates header, persists | account_ops_test "one Save writes ..."; dual "settings: one Save applies names and currency" |
| margin mode stores minimums + margin | plan_panel_test "in margin mode the save stores minimums + margin"; plan_test |
| log all balances reconciles each active debt | debt_components LogAllBalancesModal; debt_flows_browser "log all balances" |
| auto-logged: requires due day when tracking on | holo/debt_logic_test.exs "an installment debt with confirm tracking needs a due day" |
| auto-logged: passed confirm-mode due date shows prompt | debt_logic_test "before this month's due day..."; debt_components "a confirm-mode due payment prompts" |
| auto-logged: "Log it" posts payment | debt_flows_browser / dual "due prompt: Log it posts the fixed payment" |
| auto-logged: "Skip this month" | debt_flows_browser / dual "due prompt: Skip this month" |
| auto-logged: automatic payment posted in background refreshes dashboard | DROPPED: LiveView-only PubSub server push into the open socket. Hologram has no server push; the snapshot reloads on page load and after every command. (The auto-posting job itself is covered by its own context tests.) |
| tutorial auto-starts on first mount | tutorial_footer_browser "auto-starts"; tutorial_test ":auto_start" |
| tutorial skip marks seen | tutorial_footer_browser "Skip finishes and persists"; tutorial_test ":skip" |
| tutorial strategy step selects chart type | tutorial_test "steps 5 and 6 switch the chart type"; tutorial_footer_browser "steps 5 and 6" |
| tutorial click-through marks seen | tutorial_footer_browser "Next walks every step ... Finish persists" |
| "View tutorial again" resets tutorial_seen | account_ops_test "restart_tutorial resets tutorial_seen"; tutorial_test ":restart"; dual "'View tutorial again'" |
| settings modal edits no-auth display name | account_ops_test "no-auth mode" "one Save writes name..." |
| one Save writes name, tracker name, currency | account_ops_test "one Save writes name, tracker name, and currency together" |
| invalid field blocks the whole save | account_ops_test "an invalid field blocks the whole save"; account_components_test "an invalid field blocks the whole save" |
| no-auth theme toggle saves to default user | account_ops_test "the theme saves to the implicit default user" |

## dashboard_live_oidc_test.exs

| LiveView test | Covered by |
|---|---|
| redirects to /auth/login with no session user | holo/chrome_oidc_browser_test.exs (browser-tagged); NEW "GET /app without a session redirects to /auth/login" (plain ConnCase) |
| mounts the logged-in user's own workspace | components/account_components_test.exs "OIDC mode shows the display name and log out"; NEW "GET /app mounts the signed-in user's own workspace, with no switcher" |
| switcher once >1 workspace; sharing gated on ownership of current | account_components_test "OIDC mode shows the workspace switcher once the user has two workspaces"; account_ops_test "non-owners can't share, cancel or remove"; chrome_oidc_browser_test "workspace switcher switches" |
| switching workspace picks up target's currency | NEW "a switched-to workspace renders in its own currency"; account_components_test "switch_workspace stores the choice and reloads snapshot" |
| inviting unknown email -> pending that can be canceled | account_ops_test "inviting an unknown email creates a pending invitation that can be canceled"; chrome_oidc_browser_test "sharing" |
| non-owner sees name/currency read-only, no People section | account_ops_test "non-owners can't share, cancel or remove, and see read-only settings" (includes crafted submissions as no-ops) |
| owner renames workspace; later invite email has new name | NEW "renaming the workspace is reflected in the next invitation email" |
| owner sees pending + accepted, can remove member | account_ops_test "sharing with an existing user adds a member who can be removed"; account_components_test "remove_member drops the member" |
| Auth0 database user renames via Auth0 | NEW "an Auth0 database user renames themselves via Auth0" |
| Auth0 social user sees name read-only | NEW "an Auth0 social user's name is read-only and a crafted rename is ignored" |
| theme toggle saves to account; page loads apply it | account_components_test "save_theme saves to the account"; NEW "a saved theme is applied on the next page load" (SSR `data-saved-theme`) |

## Summary

New tests: 7 in `holo/cutover_gaps_test.exs`. One test DROPPED (background PubSub refresh).
No lib/ changes.

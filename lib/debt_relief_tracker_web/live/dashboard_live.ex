defmodule DebtReliefTrackerWeb.DashboardLive do
  @moduledoc """
  The single primary interface (docs/plan.md Phase 5): a narrow left rail
  with a simplified debt list, and a large main panel that's graph-first,
  switching between the payoff-plan chart types. Add/edit/mark-paid/log
  payment are all modals on this one page rather than separate CRUD routes.
  """

  use DebtReliefTrackerWeb, :live_view

  alias DebtReliefTracker.{
    Accounts,
    ActivityLog,
    Debts,
    DuePayments,
    Payments,
    Planning,
    Settings
  }

  alias DebtReliefTracker.Debts.{Debt, Calculations}
  alias DebtReliefTracker.Payments.Payment
  alias DebtReliefTracker.Settings.RetirementProfile
  alias DebtReliefTrackerWeb.{Charts, OIDC}

  @strategies [:cash_flow, :snowball, :avalanche]
  @chart_types [
    :comparison,
    :simulation,
    :monthly_payments,
    :freed_cashflow,
    :interest_breakdown,
    :retirement_roadmap
  ]

  # The onboarding tutorial: a step with no `:target` is a centered welcome
  # card (no spotlight). Steps 5-6 set `:chart_type` because the strategy
  # switcher is only rendered for non-comparison/interest_breakdown chart
  # types (see render/1) -- reaching that step must switch the chart first
  # so the target actually exists in the DOM.
  @tutorial_steps [
    %{
      target: nil,
      title: "Welcome to your debt tracker",
      body: "A quick tour of the essentials -- feel free to skip anytime.",
      chart_type: nil
    },
    %{
      target: "#add-debt-button",
      title: "Add a debt",
      body: "Start here to add each loan, credit card, or line of credit you're tracking.",
      chart_type: nil
    },
    %{
      target: "#debt-list",
      title: "Your debts",
      body:
        "Every debt you add shows up here, with quick actions to log a payment, edit, or mark it paid off.",
      chart_type: nil
    },
    %{
      target: "#budget-input",
      title: "Set your budget",
      body:
        "Tell us how much you can put toward debt each month -- this drives every payoff projection.",
      chart_type: nil
    },
    %{
      target: "#chart-type-switcher",
      title: "Chart views",
      body:
        "Switch between comparing strategies, simulating a payoff plan, and other views of your progress.",
      chart_type: :comparison
    },
    %{
      target: "#strategy-switcher",
      title: "Payoff strategies",
      body:
        "Compare snowball, avalanche, and cash-flow strategies to see which pays off your debt fastest.",
      chart_type: :simulation
    },
    %{
      target: "#settings-button",
      title: "Settings",
      body:
        "Set your currency, export your data, and come back here anytime to view this tutorial again.",
      chart_type: nil
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_scope.user
    tutorial_user = current_user || Accounts.get_default_user!()
    workspace = current_workspace(current_user)
    settings = Settings.get_settings!(workspace)
    retirement_profiles = Settings.list_retirement_profiles(workspace)
    debts = Debts.list_debts(workspace)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(DebtReliefTracker.PubSub, "workspace:#{workspace.id}")
    end

    {:ok,
     socket
     |> assign(:current_user, current_user)
     |> assign(:oidc_enabled, OIDC.enabled?())
     |> assign(:workspace, workspace)
     |> assign(:workspaces, current_user && Accounts.list_workspaces_for_user(current_user))
     |> assign(
       :pending_invitations,
       pending_invitations_for(workspace, OIDC.enabled?(), current_user)
     )
     |> assign(:share_form, to_form(%{"email" => ""}, as: :share))
     |> assign(:strategy, :cash_flow)
     |> assign(:chart_type, :comparison)
     |> assign(:chart_types, @chart_types)
     |> assign(:strategy_options, @strategies)
     |> assign(:monthly_budget, settings.monthly_budget || default_budget(debts))
     |> assign(:budget_mode, settings.budget_mode || :total)
     |> assign(:currency, settings.currency || "USD")
     |> assign(:settings, settings)
     |> assign(:retirement_profiles, retirement_profiles)
     |> assign(:modal, nil)
     |> assign(:form, nil)
     |> assign(:name_form, nil)
     |> assign(:tutorial_user, tutorial_user)
     |> assign(:tutorial, initial_tutorial(tutorial_user, connected?(socket)))
     |> maybe_push_tutorial_step()
     |> assign(:debts, debts)
     |> assign(:due_prompts, due_prompts(debts))
     |> reload_lifetime_payments()
     |> assign_plan()}
  end

  defp current_workspace(nil), do: Accounts.ensure_default_workspace!()
  defp current_workspace(%Accounts.User{} = user), do: Accounts.current_workspace_for_user(user)

  # Auto-starts the tutorial on a brand-new (or reset) user's first
  # connected mount only -- `connected?` avoids a flash of the overlay on
  # the disconnected initial render.
  defp initial_tutorial(%Accounts.User{tutorial_seen: false}, true), do: %{step: 0}
  defp initial_tutorial(_tutorial_user, _connected?), do: nil

  defp apply_tutorial_chart_type(socket, %{chart_type: nil}), do: socket

  defp apply_tutorial_chart_type(socket, %{chart_type: chart_type}) do
    socket |> assign(:chart_type, chart_type) |> push_chart_data()
  end

  defp finish_tutorial(socket) do
    {:ok, tutorial_user} = Accounts.set_tutorial_seen(socket.assigns.tutorial_user, true)

    socket
    |> assign(:tutorial_user, tutorial_user)
    |> assign(:tutorial, nil)
  end

  defp maybe_push_tutorial_step(%{assigns: %{tutorial: nil}} = socket), do: socket

  # The TutorialOverlay JS hook owns its DOM (phx-update="ignore") and
  # renders each step from scratch on `pushEvent`, rather than by patching
  # server-rendered HTML -- it has to compute the highlighted element's
  # on-screen position with `getBoundingClientRect`, which LiveView has no
  # visibility into (see assets/js/tutorial_overlay_hook.js).
  defp maybe_push_tutorial_step(%{assigns: %{tutorial: %{step: step}}} = socket) do
    tutorial_step = Enum.at(@tutorial_steps, step)

    push_event(socket, "tutorial-step", %{
      target: tutorial_step.target,
      title: tutorial_step.title,
      body: tutorial_step.body,
      step: step + 1,
      total: length(@tutorial_steps),
      is_last: step == length(@tutorial_steps) - 1
    })
  end

  defp pending_invitations_for(workspace, oidc_enabled, current_user) do
    if (oidc_enabled and current_user) && Accounts.owner?(workspace, current_user) do
      Accounts.list_pending_invitations(workspace)
    else
      []
    end
  end

  # Whether the current session may rename the workspace or change its
  # currency. In no-auth mode there's exactly one implicit user/workspace, so
  # this is always true there -- same reasoning as `current_user/1` returning
  # `nil` when OIDC is off.
  defp workspace_owner?(%{oidc_enabled: false}), do: true
  defp workspace_owner?(%{oidc_enabled: true, current_user: nil}), do: false

  defp workspace_owner?(%{oidc_enabled: true, current_user: user, workspace: workspace}) do
    Accounts.owner?(workspace, user)
  end

  defp show_retirement_prompt?(retirement_profiles, dismissed?) do
    retirement_profiles == [] and not dismissed?
  end

  # Confirmed members (owner included) who don't already have a retirement
  # profile in this workspace -- the choices offered by the retirement
  # onboarding modal's "existing member" picker.
  defp eligible_retirement_members(workspace, retirement_profiles) do
    already_profiled = MapSet.new(retirement_profiles, & &1.user_id)

    workspace
    |> Accounts.list_confirmed_members()
    |> Enum.map(& &1.user)
    |> Enum.reject(&(&1.id in already_profiled))
  end

  defp retirement_profile_changeset(workspace, "manual", params) do
    RetirementProfile.manual_changeset(%RetirementProfile{}, workspace, params)
  end

  defp retirement_profile_changeset(workspace, "member", %{"user_id" => user_id} = params) do
    RetirementProfile.member_changeset(
      %RetirementProfile{},
      workspace,
      Accounts.get_user!(user_id),
      params
    )
  end

  # The add-form's default params for whichever source is now in effect --
  # pre-selects the first eligible member so the "existing member" `<select>`
  # always has a real `user_id` from the moment the form first renders.
  defp next_add_params("member", eligible_members),
    do: %{"user_id" => to_string(hd(eligible_members).id)}

  defp next_add_params("manual", _eligible_members), do: %{}

  # A budget that at least covers minimum payments, so a brand-new workspace
  # (or the placeholder debts) shows a feasible plan instead of an
  # "insufficient budget" error on first load. The user can raise it from
  # there to see extra payments accelerate the payoff. Padded 5% over the
  # raw sum of minimums: `simulate/4` checks feasibility against balances
  # *after* a month of interest accrues, so matching the raw (pre-interest)
  # sum exactly can still fall just short.
  defp default_budget([]), do: Decimal.new("200")

  defp default_budget(debts) do
    debts
    |> Planning.total_minimum_payments()
    |> Decimal.mult(Decimal.new("1.05"))
    |> Decimal.round(0, :up)
  end

  # --- data reloading -------------------------------------------------------

  defp reload_debts(socket) do
    assign(socket, :debts, Debts.list_debts(socket.assigns.workspace))
  end

  defp reload_lifetime_payments(socket) do
    assign(
      socket,
      :lifetime_payments,
      Payments.list_payments_for_workspace(socket.assigns.workspace)
    )
  end

  defp assign_plan(socket) do
    %{debts: debts, monthly_budget: budget, strategy: strategy} = socket.assigns

    strategies =
      Map.new(@strategies, fn s -> {s, Planning.simulate(debts, budget, s)} end)

    this_month =
      case strategies[strategy] do
        {:ok, %{months: [first | _]}} -> first
        _ -> nil
      end

    socket
    |> assign(:strategies, strategies)
    |> assign(:this_month, this_month)
    |> push_chart_data()
  end

  # Computes the Chart.js config (docs/plan.md Phase 5 -- see PlanChart JS
  # hook) for whichever chart type/strategy is currently selected, and pushes
  # it to the client. `nil` config (no data yet, or the plan errored) means
  # the template shows `@chart_message` instead of the canvas.
  defp push_chart_data(socket) do
    %{
      chart_type: chart_type,
      strategy: strategy,
      strategies: strategies,
      debts: debts,
      monthly_budget: budget,
      lifetime_payments: lifetime_payments,
      currency: currency,
      retirement_profiles: retirement_profiles
    } = socket.assigns

    {message, config} =
      Charts.build(
        chart_type,
        strategy,
        strategies,
        debts,
        budget,
        lifetime_payments,
        retirement_profiles
      )

    socket = assign(socket, :chart_message, message)

    if config,
      do: push_event(socket, "plan-chart-data", Map.put(config, :currency, currency)),
      else: socket
  end

  defp refresh(socket) do
    socket =
      socket
      |> reload_debts()
      |> reload_lifetime_payments()
      |> maybe_update_default_budget()

    socket
    |> assign(:due_prompts, due_prompts(socket.assigns.debts))
    |> assign_plan()
  end

  # Confirm-mode's "payment due" prompt is derived fresh on every
  # mount/refresh from the same DueSchedule.due?/2 check the automatic-mode
  # scheduler polls -- no background process needed for this mode.
  # Automatic-mode debts are also "due" per DuePayments.due_debts/1, but
  # they're handled silently by the scheduler and shouldn't also nag here.
  defp due_prompts(debts) do
    debts
    |> DuePayments.due_debts()
    |> Enum.filter(&(&1.auto_log_mode == :confirm))
  end

  # If the user has never set an explicit budget (Settings.monthly_budget is
  # still nil), keep the assign in sync with `default_budget/1` as debts
  # change -- otherwise a workspace that started empty stays pinned to the
  # $200 placeholder from mount/3 forever, and adding a real debt whose
  # minimum payment exceeds it immediately looks like an insufficient-budget
  # error. Once the user picks a budget via `update_budget`, it's persisted
  # and this no longer applies.
  defp maybe_update_default_budget(socket) do
    settings = Settings.get_settings!(socket.assigns.workspace)

    if settings.monthly_budget do
      socket
    else
      assign(socket, :monthly_budget, default_budget(socket.assigns.debts))
    end
  end

  # An automatic-mode auto-log payment posted in the background (see
  # DuePayments.Scheduler) while this dashboard was open -- refresh so the
  # balance/activity log reflect it without waiting for a manual reload.
  @impl true
  def handle_info({:due_payment_posted, _debt_id}, socket) do
    {:noreply, socket |> refresh() |> put_flash(:info, "An automatic payment was posted.")}
  end

  # --- events: modals --------------------------------------------------------

  @impl true
  def handle_event("open_add_debt", _params, socket) do
    changeset = Debts.change_debt(%Debt{})

    {:noreply,
     socket
     |> assign(:modal, %{type: :add_debt, debt: nil})
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("open_edit_debt", %{"id" => id}, socket) do
    debt = Debts.get_debt!(socket.assigns.workspace, id)
    changeset = Debts.change_debt(debt)

    {:noreply,
     socket
     |> assign(:modal, %{type: :edit_debt, debt: debt})
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("open_log_payment", %{"id" => id}, socket) do
    debt = Debts.get_debt!(socket.assigns.workspace, id)
    changeset = Payment.changeset(%Payment{}, %{"paid_on" => Date.utc_today()})

    {:noreply,
     socket
     |> assign(:modal, %{type: :log_payment, debt: debt})
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("open_log_all_balances", _params, socket) do
    {:noreply, assign(socket, :modal, %{type: :log_all_balances})}
  end

  def handle_event("open_activity_log", _params, socket) do
    entries = ActivityLog.list_recent(socket.assigns.workspace)

    {:noreply,
     socket
     |> assign(:modal, %{type: :activity_log})
     |> stream(:activity_entries, entries, reset: true)}
  end

  def handle_event("open_settings", _params, socket) do
    %{workspace: workspace} = socket.assigns
    is_owner = workspace_owner?(socket.assigns)

    {:noreply,
     socket
     |> assign(:modal, %{
       type: :settings,
       is_owner: is_owner,
       accepted_members: if(is_owner, do: Accounts.list_workspace_members(workspace), else: [])
     })
     |> assign(:name_form, to_form(Accounts.Workspace.rename_changeset(workspace, %{})))}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, socket |> assign(:modal, nil) |> assign(:form, nil) |> assign(:name_form, nil)}
  end

  # --- events: retirement onboarding -----------------------------------------
  #
  # Two separate modal screens, not one crowded form: `:retirement_onboarding`
  # is the household roster (list + "Add person"), `:retirement_profile_form`
  # is the add/edit form, opened on demand and always returning to the roster
  # afterward. `@modal.source` tracks the add-form's "existing member" vs
  # "someone without an account" radio choice between change events;
  # `@modal.editing_profile_id` (non-nil while editing) switches
  # `validate_retirement_profile` and the submit target between the add-flow
  # and the plain per-profile `update_changeset/2`.

  def handle_event("open_retirement_onboarding", _params, socket) do
    {:noreply, assign(socket, :modal, %{type: :retirement_onboarding})}
  end

  def handle_event("open_add_retirement_profile", _params, socket) do
    %{workspace: workspace, retirement_profiles: profiles} = socket.assigns
    eligible_members = eligible_retirement_members(workspace, profiles)
    source = if eligible_members == [], do: "manual", else: "member"

    changeset =
      retirement_profile_changeset(workspace, source, next_add_params(source, eligible_members))

    {:noreply,
     socket
     |> assign(:modal, %{
       type: :retirement_profile_form,
       editing_profile_id: nil,
       editing_manual?: false,
       eligible_members: eligible_members,
       source: source
     })
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("cancel_retirement_profile_form", _params, socket) do
    {:noreply, socket |> assign(:modal, %{type: :retirement_onboarding}) |> assign(:form, nil)}
  end

  def handle_event("validate_retirement_profile", params, socket) do
    %{workspace: workspace, modal: modal, retirement_profiles: profiles} = socket.assigns
    profile_params = Map.get(params, "retirement_profile", %{})

    case modal.editing_profile_id do
      nil ->
        source = Map.get(params, "source", modal.source)

        changeset =
          workspace
          |> retirement_profile_changeset(source, profile_params)
          |> Map.put(:action, :validate)

        {:noreply,
         socket
         |> assign(:modal, %{modal | source: source})
         |> assign(:form, to_form(changeset))}

      editing_id ->
        changeset =
          profiles
          |> Enum.find(&(&1.id == editing_id))
          |> RetirementProfile.update_changeset(profile_params)
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("add_retirement_profile", params, socket) do
    %{workspace: workspace, modal: modal} = socket.assigns
    source = Map.get(params, "source", modal.source)
    profile_params = Map.get(params, "retirement_profile", %{})

    result =
      case source do
        "manual" ->
          Settings.add_manual_retirement_profile(workspace, profile_params)

        "member" ->
          user = Accounts.get_user!(profile_params["user_id"])
          Settings.add_member_retirement_profile(workspace, user, profile_params)
      end

    case result do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> assign(:retirement_profiles, Settings.list_retirement_profiles(workspace))
         |> assign(:modal, %{type: :retirement_onboarding})
         |> assign(:form, nil)
         |> put_flash(:info, "Retirement profile added.")
         |> assign_plan()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("edit_retirement_profile", %{"id" => id}, socket) do
    profile = Enum.find(socket.assigns.retirement_profiles, &(&1.id == String.to_integer(id)))
    changeset = RetirementProfile.update_changeset(profile, %{})

    {:noreply,
     socket
     |> assign(:modal, %{
       type: :retirement_profile_form,
       editing_profile_id: profile.id,
       editing_manual?: is_nil(profile.user_id),
       eligible_members: [],
       source: nil
     })
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("update_retirement_profile", %{"retirement_profile" => params}, socket) do
    %{workspace: workspace, modal: modal, retirement_profiles: profiles} = socket.assigns
    profile = Enum.find(profiles, &(&1.id == modal.editing_profile_id))

    case Settings.update_retirement_profile(profile, params) do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> assign(:retirement_profiles, Settings.list_retirement_profiles(workspace))
         |> assign(:modal, %{type: :retirement_onboarding})
         |> assign(:form, nil)
         |> assign_plan()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("delete_retirement_profile", %{"id" => id}, socket) do
    %{workspace: workspace, retirement_profiles: profiles} = socket.assigns
    profile = Enum.find(profiles, &(&1.id == String.to_integer(id)))

    {:ok, _} = Settings.delete_retirement_profile(profile)

    {:noreply,
     socket
     |> assign(:retirement_profiles, Settings.list_retirement_profiles(workspace))
     |> assign_plan()}
  end

  def handle_event("dismiss_retirement_prompt", _params, socket) do
    {:ok, settings} =
      Settings.update_settings(socket.assigns.settings, %{
        "retirement_onboarding_dismissed" => "true"
      })

    {:noreply,
     socket
     |> assign(:settings, settings)
     |> assign(:modal, nil)
     |> assign(:form, nil)}
  end

  # --- events: tutorial --------------------------------------------------------

  def handle_event("tutorial_next", _params, socket) do
    next_step = socket.assigns.tutorial.step + 1

    if next_step < length(@tutorial_steps) do
      {:noreply,
       socket
       |> assign(:tutorial, %{step: next_step})
       |> apply_tutorial_chart_type(Enum.at(@tutorial_steps, next_step))
       |> maybe_push_tutorial_step()}
    else
      {:noreply, finish_tutorial(socket)}
    end
  end

  def handle_event("tutorial_prev", _params, socket) do
    prev_step = max(socket.assigns.tutorial.step - 1, 0)

    {:noreply,
     socket
     |> assign(:tutorial, %{step: prev_step})
     |> apply_tutorial_chart_type(Enum.at(@tutorial_steps, prev_step))
     |> maybe_push_tutorial_step()}
  end

  def handle_event("tutorial_skip", _params, socket) do
    {:noreply, finish_tutorial(socket)}
  end

  def handle_event("restart_tutorial", _params, socket) do
    {:ok, tutorial_user} = Accounts.set_tutorial_seen(socket.assigns.tutorial_user, false)

    {:noreply,
     socket
     |> assign(:tutorial_user, tutorial_user)
     |> assign(:modal, nil)
     |> assign(:chart_type, :comparison)
     |> push_chart_data()
     |> assign(:tutorial, %{step: 0})
     |> maybe_push_tutorial_step()}
  end

  def handle_event("mark_paid", %{"id" => id}, socket) do
    debt = Debts.get_debt!(socket.assigns.workspace, id)
    {:ok, _} = Debts.mark_paid_off(socket.assigns.workspace, nil, debt)

    {:noreply, socket |> refresh() |> put_flash(:info, "#{debt.name} marked as paid off.")}
  end

  def handle_event("delete_debt", %{"id" => id}, socket) do
    debt = Debts.get_debt!(socket.assigns.workspace, id)
    {:ok, _} = Debts.delete_debt(socket.assigns.workspace, nil, debt)

    {:noreply,
     socket
     |> refresh()
     |> assign(:modal, nil)
     |> assign(:form, nil)
     |> put_flash(:info, "#{debt.name} deleted.")}
  end

  def handle_event("confirm_due_payment", %{"id" => id}, socket) do
    debt = Debts.get_debt!(socket.assigns.workspace, id)
    {:ok, _} = DuePayments.post_due_payment(socket.assigns.workspace, nil, debt)

    {:noreply, socket |> refresh() |> put_flash(:info, "Logged #{debt.name}'s payment.")}
  end

  def handle_event("skip_due_payment", %{"id" => id}, socket) do
    debt = Debts.get_debt!(socket.assigns.workspace, id)
    {:ok, _} = DuePayments.skip_due_payment(socket.assigns.workspace, nil, debt)

    {:noreply, socket |> refresh() |> put_flash(:info, "Skipped #{debt.name} this month.")}
  end

  # --- events: add/edit debt form -------------------------------------------

  def handle_event("validate_debt", %{"debt" => params}, socket) do
    base = (socket.assigns.modal && socket.assigns.modal.debt) || %Debt{}
    changeset = Debts.change_debt(base, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save_debt", %{"debt" => params}, socket) do
    %{workspace: workspace, modal: modal} = socket.assigns

    result =
      case modal.debt do
        nil -> Debts.create_debt(workspace, nil, params)
        debt -> Debts.update_debt(workspace, nil, debt, params)
      end

    case result do
      {:ok, debt} ->
        {:noreply,
         socket
         |> refresh()
         |> assign(:modal, nil)
         |> assign(:form, nil)
         |> put_flash(:info, "Saved #{debt.name}.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  # --- events: log a single payment ------------------------------------------

  def handle_event("validate_payment", %{"payment" => params}, socket) do
    changeset =
      Payment.changeset(%Payment{}, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save_payment", %{"payment" => params}, socket) do
    %{workspace: workspace, modal: %{debt: debt}} = socket.assigns

    case Payments.log_payment(workspace, nil, debt, params) do
      {:ok, %{debt: updated}} ->
        {:noreply,
         socket
         |> refresh()
         |> assign(:modal, nil)
         |> assign(:form, nil)
         |> put_flash(:info, "Logged payment on #{updated.name}.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  # --- events: log all balances at once --------------------------------------

  def handle_event("save_log_all_balances", %{"balances" => balances}, socket) do
    %{workspace: workspace, debts: debts} = socket.assigns

    Enum.each(balances, fn {id, value} ->
      debt = Enum.find(debts, &(&1.id == String.to_integer(id)))

      if debt && value != "" do
        {:ok, _} = Debts.reconcile_balance(workspace, nil, debt, value)
      end
    end)

    {:noreply,
     socket
     |> refresh()
     |> assign(:modal, nil)
     |> put_flash(:info, "Balances updated.")}
  end

  # --- events: plan controls --------------------------------------------------

  def handle_event("select_chart", %{"type" => type}, socket) do
    {:noreply, socket |> assign(:chart_type, String.to_existing_atom(type)) |> push_chart_data()}
  end

  def handle_event("select_strategy", %{"strategy" => strategy}, socket) do
    {:noreply, socket |> assign(:strategy, String.to_existing_atom(strategy)) |> assign_plan()}
  end

  def handle_event("update_budget", %{"monthly_budget" => value}, socket) do
    case Decimal.parse(value) do
      {parsed, _} when not is_nil(parsed) ->
        budget =
          case socket.assigns.budget_mode do
            :margin -> Decimal.add(Planning.total_minimum_payments(socket.assigns.debts), parsed)
            :total -> parsed
          end

        settings = Settings.get_settings!(socket.assigns.workspace)
        {:ok, _} = Settings.update_settings(settings, %{"monthly_budget" => budget})
        {:noreply, socket |> assign(:monthly_budget, budget) |> assign_plan()}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("select_budget_mode", %{"mode" => mode}, socket) do
    mode = String.to_existing_atom(mode)
    settings = Settings.get_settings!(socket.assigns.workspace)
    {:ok, _} = Settings.update_settings(settings, %{"budget_mode" => mode})
    {:noreply, assign(socket, :budget_mode, mode)}
  end

  def handle_event("select_currency", %{"currency" => currency}, socket) do
    if workspace_owner?(socket.assigns) do
      settings = Settings.get_settings!(socket.assigns.workspace)
      {:ok, _} = Settings.update_settings(settings, %{"currency" => currency})
      {:noreply, socket |> assign(:currency, currency) |> push_chart_data()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("validate_workspace_name", %{"workspace" => params}, socket) do
    changeset =
      socket.assigns.workspace
      |> Accounts.Workspace.rename_changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :name_form, to_form(changeset))}
  end

  def handle_event("update_workspace_name", %{"workspace" => params}, socket) do
    if workspace_owner?(socket.assigns) do
      case Accounts.update_workspace(socket.assigns.workspace, params) do
        {:ok, workspace} ->
          workspaces =
            socket.assigns.current_user &&
              Accounts.list_workspaces_for_user(socket.assigns.current_user)

          {:noreply,
           socket
           |> assign(:workspace, workspace)
           |> assign(:workspaces, workspaces)
           |> assign(:name_form, to_form(Accounts.Workspace.rename_changeset(workspace, %{})))
           |> put_flash(:info, "Renamed to #{workspace.name}.")}

        {:error, changeset} ->
          {:noreply, assign(socket, :name_form, to_form(changeset))}
      end
    else
      {:noreply, socket}
    end
  end

  # --- events: OIDC mode only -- workspace switching & sharing ---------------
  # (docs/architecture/0002-auth-and-sharing-model.md)

  def handle_event("switch_workspace", %{"workspace_id" => id}, socket) do
    workspace = Accounts.get_workspace!(id)
    settings = Settings.get_settings!(workspace)
    retirement_profiles = Settings.list_retirement_profiles(workspace)
    debts = Debts.list_debts(workspace)

    if connected?(socket) do
      Phoenix.PubSub.unsubscribe(
        DebtReliefTracker.PubSub,
        "workspace:#{socket.assigns.workspace.id}"
      )

      Phoenix.PubSub.subscribe(DebtReliefTracker.PubSub, "workspace:#{workspace.id}")
    end

    {:noreply,
     socket
     |> assign(:workspace, workspace)
     |> assign(
       :pending_invitations,
       pending_invitations_for(
         workspace,
         socket.assigns.oidc_enabled,
         socket.assigns.current_user
       )
     )
     |> assign(:monthly_budget, settings.monthly_budget || default_budget(debts))
     |> assign(:budget_mode, settings.budget_mode || :total)
     |> assign(:currency, settings.currency || "USD")
     |> assign(:settings, settings)
     |> assign(:retirement_profiles, retirement_profiles)
     |> assign(:debts, debts)
     |> assign(:due_prompts, due_prompts(debts))
     |> reload_lifetime_payments()
     |> assign_plan()}
  end

  def handle_event("share_workspace", %{"share" => %{"email" => email}}, socket) do
    case Accounts.share_workspace_with_email(
           socket.assigns.workspace,
           email,
           socket.assigns.current_user
         ) do
      {:ok, %Accounts.WorkspaceMember{}} ->
        {:noreply,
         socket
         |> assign(:workspaces, Accounts.list_workspaces_for_user(socket.assigns.current_user))
         |> assign(:share_form, to_form(%{"email" => ""}, as: :share))
         |> put_flash(:info, "Shared with #{email}.")}

      {:ok, %Accounts.WorkspaceInvitation{}} ->
        {:noreply,
         socket
         |> assign(
           :pending_invitations,
           Accounts.list_pending_invitations(socket.assigns.workspace)
         )
         |> assign(:share_form, to_form(%{"email" => ""}, as: :share))
         |> put_flash(:info, "Invited #{email} -- they'll get access once they sign in.")}

      {:error, %Ecto.Changeset{data: %Accounts.WorkspaceMember{}}} ->
        {:noreply, put_flash(socket, :error, "#{email} already has access.")}

      {:error, %Ecto.Changeset{data: %Accounts.WorkspaceInvitation{}}} ->
        {:noreply, put_flash(socket, :error, "#{email} has already been invited.")}
    end
  end

  def handle_event("cancel_invitation", %{"id" => id}, socket) do
    if Accounts.owner?(socket.assigns.workspace, socket.assigns.current_user) do
      Accounts.cancel_invitation(socket.assigns.workspace, id)
    end

    {:noreply,
     assign(
       socket,
       :pending_invitations,
       Accounts.list_pending_invitations(socket.assigns.workspace)
     )}
  end

  def handle_event("remove_member", %{"id" => id}, socket) do
    %{workspace: workspace, current_user: current_user, modal: modal} = socket.assigns

    if current_user && Accounts.owner?(workspace, current_user) do
      Accounts.remove_member(workspace, id)
    end

    {:noreply,
     assign(socket, :modal, %{
       modal
       | accepted_members: Accounts.list_workspace_members(workspace)
     })}
  end

  # --- render ------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} full_width>
      <header class="navbar px-4 border-b border-base-300 gap-3">
        <div class="flex-1 flex items-center gap-3">
          <span class="font-semibold">{@workspace.name}</span>

          <form
            :if={@oidc_enabled and length(@workspaces) > 1}
            phx-change="switch_workspace"
            class="inline"
          >
            <select name="workspace_id" class="select select-sm">
              <option :for={w <- @workspaces} value={w.id} selected={w.id == @workspace.id}>
                {w.name}
              </option>
            </select>
          </form>

          <button
            id="settings-button"
            type="button"
            phx-click="open_settings"
            class="btn btn-ghost btn-sm btn-circle"
            aria-label="Settings"
          >
            <.icon name="hero-cog-6-tooth" class="w-5 h-5" />
          </button>
        </div>

        <div :if={@oidc_enabled} class="flex-none flex items-center gap-2 text-sm">
          <span>{@current_user.display_name}</span>
          <.link href={~p"/auth/logout"} method="post" class="btn btn-ghost btn-sm">Log out</.link>
        </div>

        <div class="flex-none"><Layouts.theme_toggle /></div>
      </header>

      <div class="flex flex-1 min-h-0">
        <aside class="w-full sm:w-1/5 sm:min-w-[220px] border-r border-base-300 p-3 flex flex-col gap-3 min-h-0">
          <.button
            id="add-debt-button"
            phx-click="open_add_debt"
            class="btn btn-primary btn-sm w-full"
          >
            <.icon name="hero-plus" class="size-4" /> Add debt
          </.button>
          <.button phx-click="open_log_all_balances" class="btn btn-soft btn-sm w-full">
            Log all balances
          </.button>
          <.button phx-click="open_activity_log" class="btn btn-soft btn-sm w-full">
            Activity log
          </.button>

          <ul id="debt-list" class="flex flex-col gap-2 mt-2 flex-1 min-h-0 overflow-y-auto">
            <li
              :for={debt <- @debts}
              class={[
                "rounded border border-base-300 p-2",
                debt.exclude_from_plan && "opacity-50"
              ]}
            >
              <div class="flex items-center justify-between gap-1">
                <span class={[
                  "font-medium text-sm truncate",
                  debt.status == :paid_off && "line-through opacity-60"
                ]}>
                  {debt.name}
                </span>
                <span class="text-xs opacity-70">{debt.type}</span>
              </div>
              <div class="text-sm">
                {format_money(Calculations.estimated_balance(debt), @currency)}
                <span :if={debt.type == :revolving} class="text-xs opacity-60">est.</span>
              </div>
              <div :if={debt.type == :revolving && debt.credit_limit} class="text-xs opacity-70">
                {format_percent(Calculations.credit_utilization(debt))} utilization
              </div>
              <div class="flex gap-1 mt-1">
                <button
                  :if={debt.status != :paid_off}
                  class="btn btn-ghost btn-xs"
                  phx-click="open_log_payment"
                  phx-value-id={debt.id}
                >
                  Log payment
                </button>
                <button class="btn btn-ghost btn-xs" phx-click="open_edit_debt" phx-value-id={debt.id}>
                  Edit
                </button>
                <button
                  :if={debt.status != :paid_off}
                  class="btn btn-ghost btn-xs"
                  phx-click="mark_paid"
                  phx-value-id={debt.id}
                  data-confirm={"Mark #{debt.name} as paid off?"}
                >
                  Mark paid
                </button>
              </div>
            </li>
          </ul>
        </aside>

        <main class="flex-1 p-4 flex flex-col gap-4 overflow-y-auto">
          <div
            :if={
              show_retirement_prompt?(@retirement_profiles, @settings.retirement_onboarding_dismissed)
            }
            id="retirement-onboarding-banner"
            class="alert alert-info flex items-center justify-between"
          >
            <span>See how paying off debt sooner could grow your retirement savings.</span>
            <div class="flex items-center gap-2">
              <.button
                type="button"
                phx-click="open_retirement_onboarding"
                class="btn btn-primary btn-sm"
              >
                Set up retirement plan
              </.button>
              <button
                type="button"
                phx-click="dismiss_retirement_prompt"
                class="btn btn-ghost btn-xs"
                aria-label="Dismiss"
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>
          </div>

          <% strategy_result = @strategies[@strategy] %>
          <% debt_remaining = Calculations.total_remaining_balance(@debts) %>
          <% interest_remaining = projected_interest_remaining(strategy_result) %>
          <.stat_cards
            total_paid={Decimal.add(debt_remaining, interest_remaining)}
            interest_paid={interest_remaining}
            debt_remaining={debt_remaining}
            payoff_date={payoff_date(strategy_result)}
            payoff_months={payoff_months(strategy_result)}
            overall_utilization={Calculations.overall_credit_utilization(@debts)}
            currency={@currency}
          />

          <.this_month_card
            this_month={@this_month}
            debts={@debts}
            currency={@currency}
            due_prompts={@due_prompts}
          />

          <div class="flex flex-wrap items-center gap-4">
            <form phx-change="update_budget" class="flex items-center gap-2">
              <label class="text-sm">
                {if @budget_mode == :margin, do: "Additional margin", else: "Monthly budget"}
              </label>
              <input
                id="budget-input"
                type="number"
                step="0.01"
                name="monthly_budget"
                value={Decimal.to_string(displayed_budget(@monthly_budget, @debts, @budget_mode))}
                class="input input-sm w-28"
              />
            </form>

            <div class="join">
              <button
                class={["btn btn-xs join-item", @budget_mode == :total && "btn-primary"]}
                phx-click="select_budget_mode"
                phx-value-mode="total"
              >
                Total
              </button>
              <button
                class={["btn btn-xs join-item", @budget_mode == :margin && "btn-primary"]}
                phx-click="select_budget_mode"
                phx-value-mode="margin"
              >
                Margin
              </button>
            </div>

            <div id="chart-type-switcher" class="join">
              <button
                :for={type <- @chart_types}
                class={["btn btn-sm join-item", @chart_type == type && "btn-primary"]}
                phx-click="select_chart"
                phx-value-type={type}
              >
                {chart_label(type)}
              </button>
            </div>

            <div
              :if={@chart_type not in [:comparison, :interest_breakdown, :retirement_roadmap]}
              id="strategy-switcher"
              class="join"
            >
              <button
                :for={strategy <- @strategy_options}
                class={["btn btn-sm join-item", @strategy == strategy && "btn-primary"]}
                phx-click="select_strategy"
                phx-value-strategy={strategy}
              >
                {strategy_label(strategy)}
              </button>
            </div>
          </div>

          <div class="border border-base-300 rounded p-4 flex-1 min-h-[24rem]">
            <p :if={@chart_message}>{@chart_message}</p>
            <div :if={!@chart_message} class="relative h-full min-h-[22rem]">
              <canvas id="plan-chart" phx-hook="PlanChart" phx-update="ignore"></canvas>
            </div>
          </div>
        </main>
      </div>

      <.debt_form_modal
        :if={@modal && @modal.type in [:add_debt, :edit_debt]}
        modal={@modal}
        form={@form}
      />
      <.payment_form_modal :if={@modal && @modal.type == :log_payment} modal={@modal} form={@form} />
      <.log_all_balances_modal :if={@modal && @modal.type == :log_all_balances} debts={@debts} />
      <.activity_log_modal
        :if={@modal && @modal.type == :activity_log}
        entries={@streams.activity_entries}
        currency={@currency}
      />
      <.settings_modal
        :if={@modal && @modal.type == :settings}
        modal={@modal}
        workspace={@workspace}
        name_form={@name_form}
        currency={@currency}
        oidc_enabled={@oidc_enabled}
        share_form={@share_form}
        pending_invitations={@pending_invitations}
        settings={@settings}
        retirement_profiles={@retirement_profiles}
      />
      <.retirement_onboarding_modal
        :if={@modal && @modal.type == :retirement_onboarding}
        retirement_profiles={@retirement_profiles}
      />
      <.retirement_profile_form_modal
        :if={@modal && @modal.type == :retirement_profile_form}
        modal={@modal}
        form={@form}
      />
      <.tutorial_overlay :if={@tutorial} />
    </Layouts.app>
    """
  end

  # --- function components: cards --------------------------------------------

  attr :total_paid, :any, required: true
  attr :interest_paid, :any, required: true
  attr :debt_remaining, :any, required: true
  attr :payoff_date, :string, required: true
  attr :payoff_months, :any, required: true
  attr :overall_utilization, :any, default: nil
  attr :currency, :string, required: true

  defp stat_cards(assigns) do
    ~H"""
    <div class="stats stats-vertical sm:stats-horizontal shadow w-full">
      <div class="stat bg-purple-600 text-white">
        <div class="stat-figure"><.icon name="hero-currency-dollar" class="size-6" /></div>
        <div class="stat-title text-purple-100">Total Paid</div>
        <div class="stat-value text-2xl">{format_money(@total_paid, @currency)}</div>
      </div>
      <div class="stat bg-orange-600 text-white">
        <div class="stat-figure"><.icon name="hero-face-frown" class="size-6" /></div>
        <div class="stat-title text-orange-100">Interest Paid</div>
        <div class="stat-value text-2xl">{format_money(@interest_paid, @currency)}</div>
      </div>
      <div class="stat bg-yellow-500 text-white">
        <div class="stat-figure"><.icon name="hero-building-library" class="size-6" /></div>
        <div class="stat-title text-yellow-100">Debt Remaining</div>
        <div class="stat-value text-2xl">{format_money(@debt_remaining, @currency)}</div>
      </div>
      <div class="stat bg-teal-600 text-white">
        <div class="stat-figure"><.icon name="hero-calendar" class="size-6" /></div>
        <div class="stat-title text-teal-100">Payoff Date</div>
        <div class="stat-value text-2xl">{@payoff_date}</div>
        <div :if={@payoff_months} class="stat-desc text-teal-100">
          {@payoff_months} {if @payoff_months == 1, do: "month", else: "months"} left
        </div>
      </div>
      <div :if={@overall_utilization} class="stat bg-pink-600 text-white">
        <div class="stat-figure"><.icon name="hero-chart-pie" class="size-6" /></div>
        <div class="stat-title text-pink-100">Credit Utilization</div>
        <div class="stat-value text-2xl">{format_percent(@overall_utilization)}</div>
      </div>
    </div>
    """
  end

  attr :this_month, :any, required: true
  attr :debts, :list, required: true
  attr :currency, :string, required: true
  attr :due_prompts, :list, required: true

  defp this_month_card(assigns) do
    ~H"""
    <div class="border border-base-300 rounded p-4">
      <h2 class="font-semibold mb-1">This month</h2>
      <div
        :for={debt <- @due_prompts}
        class="alert alert-warning flex justify-between items-center mb-2"
      >
        <span>{debt.name} payment ({format_money(debt.fixed_payment, @currency)}) is due.</span>
        <div class="flex gap-2">
          <.button phx-click="confirm_due_payment" phx-value-id={debt.id} variant="primary">
            Log it
          </.button>
          <.button phx-click="skip_due_payment" phx-value-id={debt.id}>Skip this month</.button>
        </div>
      </div>
      <p :if={@this_month == nil and @debts == []}>Add a debt to see your payoff plan.</p>
      <p :if={@this_month == nil and @debts != []}>
        Your monthly budget doesn't cover minimum payments yet -- increase it below.
      </p>
      <div :if={@this_month} class="flex flex-wrap gap-4 text-sm">
        <div :for={line <- @this_month.lines} :if={Decimal.positive?(line.payment)}>
          <span class="font-medium">{debt_name(@debts, line.debt_id)}</span>:
          pay {format_money(line.payment, @currency)}
          <span :if={line.debt_id == @this_month.target_debt_id} class="badge badge-primary badge-sm">
            extra
          </span>
        </div>
      </div>
    </div>
    """
  end

  # Chart rendering itself lives in DebtReliefTrackerWeb.Charts (config
  # building) and the client-side PlanChart hook (Chart.js) -- see the
  # <canvas phx-hook="PlanChart"> element in render/1 above.

  # --- function components: modals -------------------------------------------

  attr :modal, :map, required: true
  attr :form, :any, required: true

  defp debt_form_modal(assigns) do
    type = Phoenix.HTML.Form.input_value(assigns.form, :type)
    auto_log_mode = Phoenix.HTML.Form.input_value(assigns.form, :auto_log_mode)

    assigns = assign(assigns, type: type, auto_log_mode: auto_log_mode)

    ~H"""
    <.modal on_cancel="close_modal">
      <h2 class="font-semibold text-lg mb-4">
        {if @modal.type == :add_debt, do: "Add debt", else: "Edit debt"}
      </h2>
      <.form for={@form} phx-change="validate_debt" phx-submit="save_debt" class="flex flex-col gap-1">
        <.input field={@form[:name]} label="Name" />
        <.input
          field={@form[:type]}
          type="select"
          label="Type"
          options={[
            {"Revolving (credit card)", "revolving"},
            {"Installment (loan, BNPL)", "installment"}
          ]}
          prompt="Choose a type"
        />
        <.input field={@form[:balance]} type="number" step="0.01" label="Current balance" />
        <.input
          field={@form[:original_balance]}
          type="number"
          step="0.01"
          label="Original balance (optional)"
        />
        <.input field={@form[:apr]} type="number" step="0.01" label="APR %" />

        <div :if={@type == :revolving || @type == "revolving"}>
          <.input
            field={@form[:minimum_payment_floor]}
            type="number"
            step="0.01"
            label="Minimum payment floor"
          />
          <.input
            field={@form[:minimum_payment_rate]}
            type="number"
            step="0.001"
            label="Minimum payment rate (e.g. 0.02 for 2%)"
          />
          <.input
            field={@form[:credit_limit]}
            type="number"
            step="0.01"
            label="Credit limit (optional)"
          />
        </div>

        <div :if={@type == :installment || @type == "installment"}>
          <.input
            field={@form[:fixed_payment]}
            type="number"
            step="0.01"
            label="Fixed monthly payment"
          />
          <.input
            field={@form[:auto_log_mode]}
            type="select"
            label="Due-date tracking"
            options={[
              {"Off", "off"},
              {"Prompt me to confirm", "confirm"},
              {"Post automatically", "automatic"}
            ]}
          />
          <.input
            :if={@auto_log_mode in [:confirm, :automatic, "confirm", "automatic"]}
            field={@form[:due_day]}
            type="number"
            min="1"
            max="31"
            label="Due day of month"
          />
        </div>

        <.input
          field={@form[:exclude_from_plan]}
          type="checkbox"
          label="Exclude from consumer payoff plan"
        />

        <div class="flex justify-between gap-2 mt-2">
          <button
            :if={@modal.type == :edit_debt}
            type="button"
            class="btn btn-error btn-outline"
            phx-click="delete_debt"
            phx-value-id={@modal.debt.id}
            data-confirm={"Delete #{@modal.debt.name}? This can't be undone."}
          >
            Delete
          </button>
          <div class="flex gap-2 ml-auto">
            <.button type="button" phx-click="close_modal">Cancel</.button>
            <.button type="submit" variant="primary">Save</.button>
          </div>
        </div>
      </.form>
    </.modal>
    """
  end

  attr :modal, :map, required: true
  attr :form, :any, required: true

  defp payment_form_modal(assigns) do
    ~H"""
    <.modal on_cancel="close_modal">
      <h2 class="font-semibold text-lg mb-4">Log payment -- {@modal.debt.name}</h2>
      <.form
        for={@form}
        phx-change="validate_payment"
        phx-submit="save_payment"
        class="flex flex-col gap-1"
      >
        <.input field={@form[:amount]} type="number" step="0.01" label="Amount paid" />
        <.input
          field={@form[:principal_portion]}
          type="number"
          step="0.01"
          label="Principal portion (optional)"
        />
        <.input
          field={@form[:interest_portion]}
          type="number"
          step="0.01"
          label="Interest portion (optional)"
        />
        <.input field={@form[:paid_on]} type="date" label="Paid on" />
        <.input field={@form[:note]} label="Note (optional)" />

        <div class="flex justify-end gap-2 mt-2">
          <.button type="button" phx-click="close_modal">Cancel</.button>
          <.button type="submit" variant="primary">Log payment</.button>
        </div>
      </.form>
    </.modal>
    """
  end

  attr :debts, :list, required: true

  defp log_all_balances_modal(assigns) do
    active_debts = Enum.filter(assigns.debts, &(&1.status != :paid_off))
    assigns = assign(assigns, :active_debts, active_debts)

    ~H"""
    <.modal on_cancel="close_modal">
      <h2 class="font-semibold text-lg mb-4">Log all balances</h2>
      <form phx-submit="save_log_all_balances" class="flex flex-col gap-2">
        <div :for={debt <- @active_debts} class="flex items-center gap-2">
          <label class="w-40 text-sm truncate">{debt.name}</label>
          <input
            type="number"
            step="0.01"
            name={"balances[#{debt.id}]"}
            value={Decimal.to_string(Calculations.estimated_balance(debt))}
            class="input input-sm flex-1"
          />
        </div>
        <div class="flex justify-end gap-2 mt-2">
          <.button type="button" phx-click="close_modal">Cancel</.button>
          <.button type="submit" variant="primary">Save balances</.button>
        </div>
      </form>
    </.modal>
    """
  end

  attr :entries, :any, required: true
  attr :currency, :string, required: true

  defp activity_log_modal(assigns) do
    ~H"""
    <.modal on_cancel="close_modal">
      <h2 class="font-semibold text-lg mb-4">Activity log</h2>
      <.table id="activity-log-entries" rows={@entries} row_item={fn {_id, entry} -> entry end}>
        <:col :let={entry} label="When">
          {Calendar.strftime(entry.inserted_at, "%b %d, %Y %I:%M %p")}
        </:col>
        <:col :let={entry} label="Activity">{activity_description(entry, @currency)}</:col>
      </.table>
      <div class="flex justify-end mt-4">
        <.button type="button" phx-click="close_modal">Close</.button>
      </div>
    </.modal>
    """
  end

  attr :modal, :map, required: true
  attr :workspace, :map, required: true
  attr :name_form, :any, required: true
  attr :currency, :string, required: true
  attr :oidc_enabled, :boolean, required: true
  attr :share_form, :any, required: true
  attr :pending_invitations, :list, required: true
  attr :settings, :map, required: true
  attr :retirement_profiles, :list, required: true

  defp settings_modal(assigns) do
    ~H"""
    <.modal on_cancel="close_modal">
      <h2 class="font-semibold text-lg mb-4">Settings</h2>

      <section class="mb-6">
        <h3 class="font-medium mb-2">Tracker name</h3>
        <.form
          :if={@modal.is_owner}
          for={@name_form}
          id="workspace-name-form"
          phx-change="validate_workspace_name"
          phx-submit="update_workspace_name"
          class="flex items-center gap-2"
        >
          <.input field={@name_form[:name]} />
          <.button type="submit" variant="primary" class="btn-sm">Save</.button>
        </.form>
        <p :if={!@modal.is_owner} class="text-sm opacity-70">{@workspace.name}</p>
      </section>

      <section class="mb-6">
        <h3 class="font-medium mb-2">Currency</h3>
        <form :if={@modal.is_owner} phx-change="select_currency">
          <select name="currency" class="select select-sm">
            <option :for={code <- currency_codes()} value={code} selected={code == @currency}>
              {code}
            </option>
          </select>
        </form>
        <p :if={!@modal.is_owner} class="text-sm opacity-70">{@currency}</p>
      </section>

      <section class="mb-6">
        <h3 class="font-medium mb-2">Export</h3>
        <div class="flex flex-col gap-2">
          <.link href={~p"/export/debts.csv"} class="btn btn-soft btn-sm w-full">
            Export debts (CSV)
          </.link>
          <.link href={~p"/export/payments.csv"} class="btn btn-soft btn-sm w-full">
            Export payments (CSV)
          </.link>
        </div>
      </section>

      <section class="mb-6">
        <h3 class="font-medium mb-2">Tutorial</h3>
        <.button type="button" phx-click="restart_tutorial" class="btn btn-soft btn-sm">
          View tutorial again
        </.button>
      </section>

      <section class="mb-6">
        <h3 class="font-medium mb-2">Retirement planning</h3>
        <p :if={@retirement_profiles == []} class="text-sm opacity-70 mb-2">Not set up yet.</p>
        <ul :if={@retirement_profiles != []} class="text-sm opacity-70 mb-2">
          <li :for={profile <- @retirement_profiles}>
            {RetirementProfile.display_name(profile)}: retiring at {profile.retirement_age} (currently {profile.current_age})
          </li>
        </ul>
        <.button type="button" phx-click="open_retirement_onboarding" class="btn btn-soft btn-sm">
          {if @retirement_profiles == [],
            do: "Set up retirement profile",
            else: "Manage retirement profiles"}
        </.button>
      </section>

      <section :if={@oidc_enabled and @modal.is_owner}>
        <h3 class="font-medium mb-2">People</h3>
        <.form
          for={@share_form}
          id="settings-share-form"
          phx-submit="share_workspace"
          class="flex items-center gap-2 mb-3"
        >
          <input
            type="email"
            name="share[email]"
            placeholder="Invite by email…"
            class="input input-sm flex-1"
          />
          <.button type="submit" class="btn btn-sm">Invite</.button>
        </.form>

        <ul class="flex flex-col gap-1">
          <li
            :for={invitation <- @pending_invitations}
            class="flex items-center justify-between text-sm"
          >
            <span>{invitation.email} <span class="badge badge-ghost badge-sm">pending</span></span>
            <button
              type="button"
              phx-click="cancel_invitation"
              phx-value-id={invitation.id}
              aria-label={"Cancel invitation for #{invitation.email}"}
            >
              <.icon name="hero-x-mark" class="w-3 h-3" />
            </button>
          </li>
          <li
            :for={member <- @modal.accepted_members}
            class="flex items-center justify-between text-sm"
          >
            <span>{member.user.display_name}</span>
            <button
              type="button"
              phx-click="remove_member"
              phx-value-id={member.id}
              aria-label={"Remove #{member.user.display_name}"}
            >
              <.icon name="hero-x-mark" class="w-3 h-3" />
            </button>
          </li>
        </ul>
      </section>

      <div class="flex justify-end mt-4">
        <.button type="button" phx-click="close_modal">Close</.button>
      </div>
    </.modal>
    """
  end

  attr :retirement_profiles, :list, required: true

  defp retirement_onboarding_modal(assigns) do
    ~H"""
    <.modal on_cancel="close_modal">
      <h2 class="font-semibold text-lg mb-4">Plan your household's retirement</h2>
      <p class="text-sm opacity-70 mb-4">
        See how paying off debt sooner grows your household's retirement savings, by redirecting
        more of everyone's income into investing once you're debt-free.
      </p>

      <p :if={@retirement_profiles == []} class="text-sm opacity-70 mb-4">
        No one in the household has a retirement profile yet.
      </p>

      <ul :if={@retirement_profiles != []} class="flex flex-col gap-2 mb-4">
        <li :for={profile <- @retirement_profiles} class="flex items-center justify-between text-sm">
          <span>
            {RetirementProfile.display_name(profile)} -- retiring at {profile.retirement_age} (currently {profile.current_age})
          </span>
          <div class="flex gap-2">
            <button type="button" phx-click="edit_retirement_profile" phx-value-id={profile.id}>
              <.icon name="hero-pencil" class="w-3 h-3" />
            </button>
            <button type="button" phx-click="delete_retirement_profile" phx-value-id={profile.id}>
              <.icon name="hero-x-mark" class="w-3 h-3" />
            </button>
          </div>
        </li>
      </ul>

      <.button
        type="button"
        phx-click="open_add_retirement_profile"
        class="btn btn-soft btn-sm w-full mb-4"
      >
        <.icon name="hero-plus" class="w-4 h-4" /> Add person
      </.button>

      <div class="flex justify-end gap-2 mt-2">
        <.button
          :if={@retirement_profiles == []}
          type="button"
          phx-click="dismiss_retirement_prompt"
        >
          Skip for now
        </.button>
        <.button type="button" phx-click="close_modal">Close</.button>
      </div>
    </.modal>
    """
  end

  attr :modal, :map, required: true
  attr :form, :any, required: true

  defp retirement_profile_form_modal(assigns) do
    adding? = is_nil(assigns.modal.editing_profile_id)
    show_member_picker? = adding? and assigns.modal.source == "member"

    show_manual_fields? =
      (adding? and assigns.modal.source == "manual") or
        (not adding? and assigns.modal.editing_manual?)

    assigns =
      assign(assigns,
        adding?: adding?,
        show_member_picker?: show_member_picker?,
        show_manual_fields?: show_manual_fields?
      )

    ~H"""
    <.modal on_cancel="cancel_retirement_profile_form">
      <h2 class="font-semibold text-lg mb-4">
        {if @adding?, do: "Add a person", else: "Edit retirement profile"}
      </h2>

      <.form
        for={@form}
        id="retirement-profile-form"
        phx-change="validate_retirement_profile"
        phx-submit={if @adding?, do: "add_retirement_profile", else: "update_retirement_profile"}
        class="flex flex-col gap-3"
      >
        <div :if={@adding? and @modal.eligible_members != []} class="flex gap-4 text-sm">
          <label class="flex items-center gap-1">
            <input type="radio" name="source" value="member" checked={@modal.source == "member"} />
            Existing member
          </label>
          <label class="flex items-center gap-1">
            <input type="radio" name="source" value="manual" checked={@modal.source == "manual"} />
            Someone without an account
          </label>
        </div>

        <.input
          :if={@show_member_picker?}
          field={@form[:user_id]}
          type="select"
          label="Household member"
          options={Enum.map(@modal.eligible_members, &{&1.display_name, &1.id})}
        />

        <.input :if={@show_manual_fields?} field={@form[:name]} label="Name" />
        <.input
          :if={@show_manual_fields?}
          field={@form[:claim_email]}
          type="email"
          label="Email (optional -- links their account automatically if they sign in later)"
        />

        <.input field={@form[:current_age]} type="number" label="Current age" />
        <.input field={@form[:retirement_age]} type="number" label="Target retirement age" />
        <.input
          field={@form[:current_retirement_savings]}
          type="number"
          step="0.01"
          label="Current retirement savings"
        />
        <.input
          field={@form[:monthly_retirement_contribution]}
          type="number"
          step="0.01"
          label="Current monthly retirement contribution"
        />
        <.input
          field={@form[:monthly_gross_income]}
          type="number"
          step="0.01"
          label="Monthly gross income"
        />
        <.input
          field={@form[:post_debt_investment_pct]}
          type="number"
          step="0.1"
          label="% of income to invest once debt-free"
        />
        <.input
          field={@form[:expected_annual_return_pct]}
          type="number"
          step="0.1"
          label="Expected annual return (%)"
        />
        <div class="flex justify-end gap-2 mt-2">
          <.button type="button" phx-click="cancel_retirement_profile_form">Cancel</.button>
          <.button type="submit" variant="primary">
            {if @adding?, do: "Add person", else: "Save"}
          </.button>
        </div>
      </.form>
    </.modal>
    """
  end

  attr :on_cancel, :string, required: true
  slot :inner_block, required: true

  defp modal(assigns) do
    ~H"""
    <div
      class="fixed inset-0 bg-black/50 flex items-center justify-center z-50"
      phx-window-keydown={@on_cancel}
      phx-key="escape"
    >
      <div
        class="bg-base-100 rounded-lg p-6 w-full max-w-2xl max-h-[90vh] overflow-y-auto"
        phx-click-away={@on_cancel}
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # The overlay's whole lifecycle -- spotlight, tooltip, Next/Back/Skip
  # buttons -- is built and torn down by the TutorialOverlay hook itself via
  # `pushEvent`/`handleEvent` (like PlanChart's canvas), so this container
  # has no server-rendered content for LiveView to patch.
  defp tutorial_overlay(assigns) do
    ~H"""
    <div id="tutorial-overlay" phx-hook="TutorialOverlay" phx-update="ignore"></div>
    """
  end

  # --- formatting helpers ------------------------------------------------

  defp displayed_budget(monthly_budget, _debts, :total), do: monthly_budget

  defp displayed_budget(monthly_budget, debts, :margin) do
    Decimal.sub(monthly_budget, Planning.total_minimum_payments(debts))
  end

  # Interest still to be paid over the rest of the loan's life under the
  # selected strategy's simulation -- not what's already been paid.
  defp projected_interest_remaining({:ok, %{total_interest: interest}}), do: interest
  defp projected_interest_remaining(_), do: Decimal.new(0)

  defp payoff_date({:ok, %{total_months: months}}) do
    Date.utc_today() |> add_months(months) |> Calendar.strftime("%b %Y")
  end

  defp payoff_date(_), do: "—"

  defp payoff_months({:ok, %{total_months: months}}), do: months
  defp payoff_months(_), do: nil

  defp add_months(date, months) do
    total = date.year * 12 + (date.month - 1) + months
    Date.new!(div(total, 12), rem(total, 12) + 1, 1)
  end

  @currency_symbols %{
    "USD" => "$",
    "EUR" => "€",
    "GBP" => "£",
    "CAD" => "$",
    "AUD" => "$",
    "JPY" => "¥"
  }

  defp currency_codes, do: Map.keys(@currency_symbols)

  defp format_money(%Decimal{} = d, currency) do
    rounded = Decimal.round(d, 2)
    sign = if Decimal.negative?(rounded), do: "-", else: ""
    symbol = Map.get(@currency_symbols, currency, "$")

    {int_part, dec_part} =
      case rounded |> Decimal.abs() |> Decimal.to_string(:normal) |> String.split(".") do
        [int_part, dec_part] -> {int_part, dec_part}
        [int_part] -> {int_part, "00"}
      end

    "#{sign}#{symbol}#{group_thousands(int_part)}.#{String.pad_trailing(dec_part, 2, "0")}"
  end

  defp format_money(_, currency), do: "#{Map.get(@currency_symbols, currency, "$")}0.00"

  defp format_percent(%Decimal{} = d) do
    "#{d |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_string(:normal)}%"
  end

  defp format_percent(_), do: "0%"

  defp group_thousands(digits) do
    digits
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp strategy_label(strategy), do: Charts.strategy_label(strategy)
  defp debt_name(debts, id), do: Charts.debt_name(debts, id)

  # --- activity log formatting -----------------------------------------------

  defp activity_description(%{action: :debt_added} = e, _currency),
    do: "#{actor(e)} added #{debt_or_name(e)}"

  defp activity_description(%{action: :debt_updated} = e, _currency),
    do: "#{actor(e)} updated #{debt_or_name(e)}"

  defp activity_description(%{action: :debt_paid_off} = e, _currency),
    do: "#{actor(e)} marked #{debt_or_name(e)} as paid off"

  defp activity_description(%{action: :debt_deleted} = e, _currency),
    do: "#{actor(e)} deleted #{debt_or_name(e)}"

  defp activity_description(%{action: :payment_logged} = e, currency) do
    "#{actor(e)} logged a #{format_money_string(e.metadata["amount"], currency)} payment on #{debt_or_name(e)}"
  end

  defp activity_description(%{action: :payment_auto_logged} = e, currency) do
    "Auto-logged a #{format_money_string(e.metadata["amount"], currency)} payment on #{debt_or_name(e)}"
  end

  defp activity_description(%{action: :due_payment_skipped} = e, _currency) do
    "#{actor(e)} skipped this month's payment on #{debt_or_name(e)}"
  end

  defp actor(%{user: %{display_name: name}}) when is_binary(name), do: name
  defp actor(_), do: "Someone"

  defp debt_or_name(%{debt: %{name: name}}), do: name
  defp debt_or_name(%{metadata: %{"name" => name}}), do: name
  defp debt_or_name(_), do: "a debt"

  defp format_money_string(nil, _currency), do: "an unknown amount"
  defp format_money_string(str, currency), do: format_money(Decimal.new(str), currency)

  defp chart_label(:comparison), do: "Compare strategies"
  defp chart_label(:simulation), do: "Payoff simulation"
  defp chart_label(:monthly_payments), do: "Monthly payments"
  defp chart_label(:freed_cashflow), do: "Cash flow freed"
  defp chart_label(:interest_breakdown), do: "Interest vs. principal"
  defp chart_label(:retirement_roadmap), do: "Retirement roadmap"
end

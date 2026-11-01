defmodule DebtReliefTracker.DuePayments.Scheduler do
  @moduledoc """
  Polls for `:automatic`-mode installment debts whose due date has arrived,
  and posts them unattended (`DuePayments.post_due_payment/4` with
  `user: nil`). A plain `GenServer` rather than a job-queue library (e.g.
  Oban): this app has no existing job infrastructure, runs single-instance
  self-hosted, and the job itself is "check hourly whether a date has
  passed" -- Oban would need its own migrations/wiring across both
  `Repo.Sqlite` and `Repo.Postgres` for something this simple.

  Checking hourly (rather than daily, or exactly at the due time) is
  plenty of resolution for a day-granularity `due_day`, and
  `DueSchedule.due?/2` compares dates rather than requiring an exact match,
  so a missed check -- the container was stopped over the due date --
  still gets caught and posted on the next check instead of silently
  skipping that cycle.

  `:confirm`-mode debts need no scheduler involvement at all: their "payment
  due" prompt is computed fresh by the Hologram dashboard on every load/refresh
  using the same `DueSchedule.due?/2`.
  """

  use GenServer

  require Logger

  alias DebtReliefTracker.{Accounts, Debts, DuePayments}
  alias DebtReliefTracker.E2EE.Migration

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if enabled?() do
      Process.send_after(self(), :check_due_payments, initial_delay())
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:check_due_payments, state) do
    run_due_checks()
    Process.send_after(self(), :check_due_payments, interval())
    {:noreply, state}
  end

  @doc "The sweep itself, factored out so tests can call it directly without going through the timer."
  def run_due_checks do
    # A workspace with a vault is encrypted or mid-migration: its authoritative
    # data is the vault (plus plaintext being migrated, guarded by a digest),
    # so the server must never post into it (E2EE.Migration, ADR 0007).
    encrypted = Migration.encrypted_workspace_ids()

    for workspace <- Accounts.list_workspaces(),
        not MapSet.member?(encrypted, workspace.id),
        debt <- Debts.list_debts(workspace),
        debt.type == :installment,
        debt.status == :active,
        debt.auto_log_mode == :automatic,
        DebtReliefTracker.Debts.DueSchedule.due?(debt) do
      post(workspace, debt)
    end

    :ok
  end

  defp post(workspace, debt) do
    case DuePayments.post_due_payment(workspace, nil, debt) do
      {:ok, %{debt: updated}} ->
        Phoenix.PubSub.broadcast(
          DebtReliefTracker.PubSub,
          "workspace:#{workspace.id}",
          {:due_payment_posted, updated.id}
        )

      {:error, reason} ->
        Logger.error("auto-log payment failed for debt #{debt.id}: #{failure_class(reason)}")
    end
  end

  defp enabled?, do: Application.get_env(:debt_relief_tracker, :run_scheduler, true)

  defp interval,
    do: Application.get_env(:debt_relief_tracker, :due_payment_check_interval_ms, :timer.hours(1))

  defp initial_delay,
    do:
      Application.get_env(:debt_relief_tracker, :due_payment_initial_delay_ms, :timer.seconds(30))

  # Never log the reason itself: a changeset carries the submitted values
  # (amounts). Only the class / failing field names.
  defp failure_class(%Ecto.Changeset{errors: errors}),
    do: "invalid changeset, fields: #{inspect(Keyword.keys(errors))}"

  defp failure_class(reason) when is_atom(reason), do: inspect(reason)
  defp failure_class(_reason), do: "unexpected error"
end

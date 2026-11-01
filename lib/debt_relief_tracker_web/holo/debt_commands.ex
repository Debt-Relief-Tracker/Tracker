defmodule DebtReliefTrackerWeb.Holo.DebtCommands do
  @moduledoc """
  Server-only helper shared by the debt components' `command/3` clauses.

  A Hologram `Server` carries a single `next_action` (a later `put_action`
  overwrites an earlier one), so a command cannot say "update the snapshot,
  close the modal, show a notice" as three actions. Instead the result goes to
  the sidebar's `:synced` action, which sets its notice and "today" and relays
  `:snapshot_updated` (with `close_modal: true` when asked) to the page.
  """

  import Hologram.Component, only: [put_action: 2]

  alias DebtReliefTrackerWeb.Holo.Context

  @doc """
  Applies `changes` in order, stopping at the first error. Success ->
  `:synced` on the sidebar; failure -> `:save_failed` (or `failure_action`)
  on the component whose command this is.
  """
  def run(server, changes, notice, opts \\ []) do
    close_modal = Keyword.get(opts, :close_modal, false)
    failure_action = Keyword.get(opts, :failure_action, :save_failed)

    case apply_all(server, changes) do
      {:ok, snapshot} ->
        put_action(server,
          name: :synced,
          target: "debt_sidebar",
          params: %{
            snapshot: snapshot,
            today: Context.today_iso(),
            notice: notice,
            close_modal: close_modal
          }
        )

      {:error, error} ->
        put_action(server, name: failure_action, params: %{error: error})
    end
  end

  defp apply_all(server, []), do: Context.load(server)

  defp apply_all(server, changes) do
    Enum.reduce_while(changes, nil, fn change, _acc ->
      case Context.apply_change(server, change) do
        {:ok, snapshot} -> {:cont, {:ok, snapshot}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end

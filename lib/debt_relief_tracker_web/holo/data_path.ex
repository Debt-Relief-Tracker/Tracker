defmodule DebtReliefTrackerWeb.Holo.DataPath do
  @moduledoc """
  How a feature component saves a change to the financial data, in BOTH modes
  (ADR 0007, "Data path"). Client-safe; called from component actions.

    * Plaintext mode: the component's own server `command/3` applies the
      `Storage` change(s) (`Holo.Context.apply_change/2` ->
      `Storage.Plain`) and replies with an action.
    * E2EE mode: the server cannot read or write the data, so the same
      component action sends the changes to the page (`:vault_apply_request`
      -> `VaultFlow.apply_request/2` -> `VaultDoc.Ledger` on the decrypted
      document in the browser -> debounced encrypted save). The reply is the
      same shape as the command's: the `ok` / `error` action of the
      component, with `snapshot` (and `today`) in its params.

  A component declares `prop :e2ee, :boolean, from_context: :e2ee` (the page
  puts the flag in the context) and calls `save/4` instead of `put_command/3`:

      DataPath.save(component, :save, %{changes: changes, notice: n},
        changes: changes,
        ok: DataPath.ok(:snapshot_updated, "page"),
        error: DataPath.error(:save_failed)
      )

  Plaintext behaviour is unchanged (`save/4` is exactly `put_command/3`
  there), and the validation / error rendering code after the reply is shared.
  A handler can queue only one follow-up action, so `save/4` in E2EE mode
  takes that slot; the debounced save is a JS timer (`VaultEnv.flush_later/2`).
  """

  import Hologram.Component, only: [put_command: 3, put_action: 2]

  @doc "True when the component runs in E2EE mode (its `:e2ee` context prop)."
  def e2ee?(component), do: component.props.e2ee == true

  @doc """
  Sends `command`/`command_params` to the server in plaintext mode; in E2EE
  mode applies `request.changes` through the page's ledger path. `request`:
  `changes` (list of `Storage` changes), `ok` / `error` (reply actions, see
  `ok/3` / `error/2`; default: `:snapshot_updated` on the page / `:save_failed`
  on the component) and `members` (retirement member picker, account data).
  """
  def save(component, command, command_params, request) do
    if e2ee?(component) do
      put_action(component,
        name: :vault_apply_request,
        target: "page",
        params: %{
          changes: Keyword.fetch!(request, :changes),
          ok: Keyword.get(request, :ok, ok(:snapshot_updated, "page")),
          error: Keyword.get(request, :error, error(:save_failed, component.props.cid)),
          members: Keyword.get(request, :members)
        }
      )
    else
      put_command(component, command, command_params)
    end
  end

  @doc "Reply on success: action `name` on `target`, with `params` plus `snapshot`/`today`."
  def ok(name, target, params \\ %{}), do: %{name: name, target: target, params: params}

  @doc "Reply on failure: action `name` on `target` with `%{error: error}`."
  def error(name, target), do: %{name: name, target: target}

  @doc "The ledger-path reply for a debt command: the sidebar's `:synced` (notice, close modal)."
  def synced(notice, close_modal),
    do: ok(:synced, "debt_sidebar", %{notice: notice, close_modal: close_modal})
end

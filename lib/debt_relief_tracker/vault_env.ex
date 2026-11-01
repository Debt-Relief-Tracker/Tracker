defmodule DebtReliefTracker.VaultEnv do
  @moduledoc """
  Elixir facade over `assets/js/vault_env.mjs`: the browser environment of an
  unlocked E2EE vault (clock, UUIDs, idle timer, cross-tab lock, tab
  visibility, unsaved-changes warning). No secrets pass through here -- the
  cross-tab channel only ever carries the words "locked"/"unlocked".

  The JS side reports back by dispatching the page action
  `:vault_session_event %{kind: "idle" | "visible" | "remote_locked" |
  "remote_unlocked"}`. Only usable from Hologram actions; on the server these
  are no-ops (the JS interop returns `:ok`), so each function falls back to a
  harmless value.
  """

  use Hologram.JS

  js_import from: "../../assets/js/vault_env.mjs", as: :VaultEnv

  def init(workspace_id), do: call(:envInit, [workspace_id])
  @doc """
  After `ms`, dispatches the page action `:vault_flush %{token: <string>}`
  (the save loop's debounce). A JS timer, so the calling Hologram handler's
  single follow-up action stays available.
  """
  def flush_later(token, ms), do: call(:flushLater, [Integer.to_string(token), ms])

  def idle_start(ms), do: call(:idleStart, [ms])
  def idle_stop, do: call(:idleStop, [])
  def set_dirty(flag), do: call(:setDirty, [flag])
  @doc "Tells the other tabs of this browser `\"locked\"` or `\"unlocked\"`."
  def broadcast(type), do: call(:broadcast, [type])

  @doc "Current UTC time, ISO 8601 with milliseconds."
  def now_iso, do: call(:nowIso, [])
  @doc "The user's local date, `YYYY-MM-DD`."
  def today_iso, do: call(:todayIso, [])
  @doc "A random UUID v4 (`crypto.randomUUID`)."
  def random_uuid, do: call(:randomUuid, [])
  @doc "Copies `text` to the clipboard (best effort)."
  def copy_text(text), do: call(:copyText, [text])
  @doc "Wall clock in milliseconds."
  def now_ms, do: call(:monotonicMs, [])

  defp call(function, args) do
    case JS.call(:VaultEnv, function, args) do
      :ok -> :ok
      value -> value
    end
  end
end

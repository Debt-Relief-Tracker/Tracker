defmodule DebtReliefTrackerWeb.Holo.QuietJS do
  @moduledoc """
  Elixir facade over `assets/js/hologram_quiet.mjs`: turns off Hologram's
  per-function-call profiling logs, which make client-side payoff planning
  ~25x slower (see the JS file). Client-only; call from an action before
  heavy work. The module also applies the fix when its bundle loads.
  """

  use Hologram.JS

  js_import from: "../../../assets/js/hologram_quiet.mjs", as: :hologram_quiet_js

  def quiet, do: JS.call(:hologram_quiet_js, :quiet, [])
end

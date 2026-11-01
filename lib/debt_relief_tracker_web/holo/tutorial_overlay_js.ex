defmodule DebtReliefTrackerWeb.Holo.TutorialOverlayJS do
  @moduledoc """
  Elixir facade over `assets/js/tutorial_overlay.mjs` (Hologram JS interop).
  Client-only: calling these on the server raises.
  """

  use Hologram.JS

  js_import from: "../../../assets/js/tutorial_overlay.mjs", as: :tutorial_overlay_js

  @doc """
  Measures `target` (a CSS selector or nil) and returns
  `%{"backdrop_style" => s, "card_style" => s}`. A newly shown target is
  scrolled into view.
  """
  def layout(target) do
    JS.call(:tutorial_overlay_js, :layout, [target])
  end
end

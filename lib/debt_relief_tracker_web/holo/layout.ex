defmodule DebtReliefTrackerWeb.Holo.Layout do
  @moduledoc """
  Root layout for Hologram pages (the counterpart of `Layouts.root`). Loads
  the same compiled Tailwind/daisyUI stylesheet; deliberately does NOT load
  `assets/js/app.js`, which boots a LiveView socket these pages don't have.
  """

  use Hologram.Component

  def template do
    ~HOLO"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Debt Relief Tracker</title>
        <link rel="stylesheet" href="/assets/css/app.css" />
        <Hologram.UI.Runtime />
      </head>
      <body>
        <slot />
      </body>
    </html>
    """
  end
end

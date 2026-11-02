defmodule DebtReliefTrackerWeb.Holo.Layout do
  @moduledoc """
  Root layout for Hologram pages (the counterpart of `Layouts.root`). Loads
  the same compiled Tailwind/daisyUI stylesheet; deliberately does NOT load
  `assets/js/app.js`, which boots a LiveView socket these pages don't have.

  Renders the Umami analytics script exactly when the old root layout did
  (`Layouts.umami_config/0`: configured and E2EE off). The CSP plug adds the
  Umami origin to the policy under the same condition.
  """

  use Hologram.Component

  alias DebtReliefTrackerWeb.Layouts

  # Server, first render.
  def init(_props, component, server) do
    umami =
      with cfg when is_list(cfg) <- Layouts.umami_config(),
           url when is_binary(url) <- Keyword.get(cfg, :script_url),
           id when is_binary(id) <- Keyword.get(cfg, :website_id) do
        %{script_url: url, website_id: id}
      else
        _ -> nil
      end

    {put_state(component, :umami, umami), server}
  end

  def template do
    ~HOLO"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Debt Relief Tracker</title>
        <link rel="stylesheet" href="/assets/css/app.css" />
        <script src="/assets/js/holo_account.js"></script>
        {%if @umami}
          <script defer src={@umami.script_url} data-website-id={@umami.website_id}></script>
        {/if}
        <Hologram.UI.Runtime />
      </head>
      <body>
        <slot />
      </body>
    </html>
    """
  end
end

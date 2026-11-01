defmodule DebtReliefTrackerWeb.Holo.Csrf do
  @moduledoc """
  Server-only: mints a Phoenix CSRF token from inside a Hologram command so
  the browser can make a *real* `POST` to a `:browser` pipeline route (log
  out, `/auth/logout`). Hologram pages are not rendered through Phoenix's
  CSRF plug, so the page itself has no token to embed.

  The unmasked token lives in the session under `"_csrf_token"` -- the same
  place `Plug.CSRFProtection` reads it from when the POST arrives. An existing
  one is reused (so other open tabs' tokens stay valid); otherwise one is
  generated and stored. Returns `{masked_token, server}`.
  """

  import Hologram.Server, only: [get_session: 2, put_session: 3]

  def issue(server) do
    state = Plug.CSRFProtection.dump_state_from_session(get_session(server, "_csrf_token"))
    Plug.CSRFProtection.load_state(nil, state)
    # Drop any masked token cached in this process by an earlier call.
    Process.delete(:plug_masked_csrf_token)

    token = Plug.CSRFProtection.get_csrf_token()
    new_state = Plug.CSRFProtection.dump_state()

    Process.delete(:plug_masked_csrf_token)
    Process.delete(:plug_unmasked_csrf_token)
    Process.delete(:plug_csrf_token_per_host)

    {token, put_session(server, "_csrf_token", new_state)}
  end
end

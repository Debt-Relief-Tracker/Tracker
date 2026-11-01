defmodule DebtReliefTrackerWeb.Holo.Components.VaultGateTest do
  # Not async: OIDC / E2EE config is global.
  use DebtReliefTrackerWeb.ConnCase

  import DebtReliefTracker.E2EEHelpers
  import ExUnit.CaptureLog

  alias DebtReliefTracker.E2EE.{RateLimiter, Vaults}
  alias DebtReliefTrackerWeb.Holo.Components.VaultGate
  alias DebtReliefTrackerWeb.Holo.DashboardPage
  alias Hologram.Server

  setup do
    enable_oidc()
    RateLimiter.reset()
    a = oidc_user("a")
    b = oidc_user("b")
    %{a: a, b: b, wa: workspace_of(a), wb: workspace_of(b)}
  end

  defp server_for(user), do: %Server{stash: %{holo_user_id: user.id}}

  # The one follow-up action the page receives.
  defp result(%Server{next_action: action}) do
    assert action.name == :vault_result
    assert action.target == "page"
    action.params
  end

  defp run(user, name, params),
    do: user |> server_for() |> then(&VaultGate.command(name, params, &1)) |> result()

  describe "commands" do
    test "full lifecycle through the commands", %{a: a, wa: wa} do
      assert %{op: :fetch_vault, ok: true, exists: false} = run(a, :fetch_vault, %{})

      wrap = passphrase_wrap()

      assert %{op: :create_vault, ok: true, rev: 1} =
               run(a, :create_vault, %{blob: "v1.AAAA.BBBB", wrap: wrap})

      assert %{ok: false, error: :exists} =
               run(a, :create_vault, %{blob: "other", wrap: passphrase_wrap()})

      assert %{ok: true, exists: true, rev: 1, blob: "v1.AAAA.BBBB", key_wraps: [shown]} =
               run(a, :fetch_vault, %{})

      assert shown.id == wrap.id
      assert shown.wrapped_key == wrap.wrapped_key

      assert %{ok: true, rev: 2} = run(a, :save_vault, %{base_rev: 1, blob: "v1.CCCC.DDDD"})

      assert %{ok: false, error: :conflict, rev: 2, blob: "v1.CCCC.DDDD"} =
               run(a, :save_vault, %{base_rev: 1, blob: "stale"})

      key = passkey_wrap()
      assert %{ok: true, key_wrap: %{id: id}} = run(a, :add_key_wrap, %{wrap: key})
      assert id == key.id

      assert %{ok: true} = run(a, :remove_key_wrap, %{id: wrap.id})
      assert %{ok: false, error: :last_wrap} = run(a, :remove_key_wrap, %{id: key.id})

      assert %{ok: true} = run(a, :delete_vault, %{})
      assert Vaults.fetch(wa) == :none
    end

    test "invalid input is a plain error, not a crash", %{a: a} do
      assert %{ok: false, error: :invalid} = run(a, :create_vault, %{blob: 5})
      assert %{ok: false, error: :invalid} = run(a, :save_vault, %{base_rev: "1", blob: "x"})
      assert %{ok: false, error: :invalid} = run(a, :remove_key_wrap, %{})

      assert %{ok: false, error: :invalid} =
               run(a, :create_vault, %{blob: "b", wrap: passphrase_wrap(%{kind: "x"})})
    end

    test "a client-supplied workspace id is ignored", %{a: a, wa: wa, wb: wb} do
      run(a, :create_vault, %{
        blob: "mine",
        wrap: passphrase_wrap(),
        workspace_id: wb.id
      })

      assert {:ok, %{blob: "mine"}} = Vaults.fetch(wa)
      assert Vaults.fetch(wb) == :none
    end

    test "user B can never read or modify A's vault or wraps", %{a: a, b: b, wa: wa} do
      wrap = passphrase_wrap()
      run(a, :create_vault, %{blob: "A-ONLY", wrap: wrap})

      assert %{ok: true, exists: false} = run(b, :fetch_vault, %{})
      assert %{ok: false, error: :not_found} = run(b, :save_vault, %{base_rev: 1, blob: "evil"})
      assert %{ok: false, error: :not_found} = run(b, :remove_key_wrap, %{id: wrap.id})
      assert %{ok: false, error: :not_found} = run(b, :delete_vault, %{})
      assert %{ok: false, error: :not_found} = run(b, :add_key_wrap, %{wrap: passkey_wrap()})

      assert {:ok, %{rev: 1, blob: "A-ONLY", key_wraps: [_]}} = Vaults.fetch(wa)
    end
  end

  describe "rate limiting" do
    test "commands are limited per workspace", %{a: a, b: b} do
      limited =
        for _ <- 1..40, do: run(a, :fetch_vault, %{})

      assert Enum.any?(limited, &(&1[:error] == :rate_limited))
      assert Enum.count(limited, & &1.ok) == 30
      # another workspace is unaffected
      assert %{ok: true} = run(b, :fetch_vault, %{})
    end
  end

  describe "authentication" do
    test "page and component both carry the Auth middleware" do
      for module <- [DashboardPage, VaultGate] do
        assert Enum.any?(module.__middleware__(), fn {capture, _} ->
                 Function.info(capture, :module) == {:module, DebtReliefTrackerWeb.Holo.Auth}
               end)
      end
    end

    test "with OIDC on and no session the middleware redirects to login" do
      for module <- [DashboardPage, VaultGate] do
        server = Hologram.Server.Middleware.run(%Server{}, module.__middleware__())
        assert server.status == 302
        assert server.response_headers["location"] == "/auth/login"
        assert server.stash == %{}
      end
    end

    test "a forged session user id is not accepted" do
      server =
        Hologram.Server.Middleware.run(
          %Server{session: %{"user_id" => Ecto.UUID.generate()}},
          VaultGate.__middleware__()
        )

      assert server.status == 302
    end

    test "a real session user passes and is stashed", %{a: a} do
      server =
        Hologram.Server.Middleware.run(
          %Server{session: %{"user_id" => a.id}},
          VaultGate.__middleware__()
        )

      assert server.status == nil
      assert server.stash.holo_user_id == a.id
    end

    test "GET /app without a session redirects to login", %{conn: conn} do
      enable_e2ee()
      assert redirected_to(get(conn, "/app")) == "/auth/login"
    end
  end

  describe "logs" do
    test "saving a vault logs none of the payload", %{a: a} do
      run(a, :create_vault, %{blob: "v1.INITIALINIT.INITIALINIT", wrap: passphrase_wrap()})

      marker = "SECRETMARKER" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

      wrap =
        passkey_wrap(%{
          wrapped_key: "v1.IVIVIVIV." <> marker,
          credential_id: marker <> "cred",
          salt: marker <> "salt"
        })

      old = Logger.level()
      Logger.configure(level: :debug)
      Application.put_env(:phoenix, :logger, true)

      log =
        capture_log([level: :debug], fn ->
          run(a, :save_vault, %{base_rev: 1, blob: "v1.IV." <> marker})
          run(a, :save_vault, %{base_rev: 1, blob: "v1.IV2." <> marker <> "stale"})
          run(a, :add_key_wrap, %{wrap: wrap})
          run(a, :add_key_wrap, %{wrap: %{wrap | kind: "bogus"}})
        end)

      Logger.configure(level: old)
      refute log =~ marker
      refute log =~ "INITIALINIT"
    end

    test "the vault payload keys are in Phoenix's filter_parameters" do
      configured =
        "config/config.exs"
        |> Config.Reader.read!(env: :test)
        |> get_in([:phoenix, :filter_parameters])

      for key <- ~w(blob wrapped_key salt credential_id kdf_params), do: assert(key in configured)

      params = %{
        "blob" => "S1",
        "wrap" => %{
          "wrapped_key" => "S2",
          "salt" => "S3",
          "credential_id" => "S4",
          "kdf_params" => "S5"
        },
        "keep" => "visible"
      }

      shown = params |> Phoenix.Logger.filter_values(configured) |> inspect()
      # and the live (compiled) application setting filters the same way
      assert params |> Phoenix.Logger.filter_values() |> inspect() == shown
      for secret <- ~w(S1 S2 S3 S4 S5), do: refute(shown =~ secret)
      assert shown =~ "visible"
    end
  end
end

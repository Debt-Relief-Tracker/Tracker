defmodule DebtReliefTracker.E2EETest do
  # Not async: touches application env and System env.
  use DebtReliefTracker.DataCase

  import DebtReliefTracker.E2EEHelpers

  alias DebtReliefTracker.E2EE
  alias DebtReliefTracker.E2EE.Vaults

  describe "enabled?/0 and Storage.adapter/0" do
    test "off by default, Plain adapter" do
      refute E2EE.enabled?()
      assert DebtReliefTracker.Storage.adapter() == DebtReliefTracker.Storage.Plain
    end

    test "on selects Storage.Vault, which can neither load nor change data" do
      enable_e2ee()
      assert E2EE.enabled?()
      assert DebtReliefTracker.Storage.adapter() == DebtReliefTracker.Storage.Vault

      ws = DebtReliefTracker.Accounts.ensure_default_workspace!()
      assert {:error, :e2ee_locked} = DebtReliefTracker.Storage.load(ws)

      assert {:error, :e2ee_locked} =
               DebtReliefTracker.Storage.apply_change(ws, nil, {:delete_debt, "x"})
    end

    test "an explicit :storage override wins" do
      enable_e2ee()
      Application.put_env(:debt_relief_tracker, :storage, DebtReliefTracker.Storage.Plain)
      on_exit(fn -> Application.delete_env(:debt_relief_tracker, :storage) end)
      assert DebtReliefTracker.Storage.adapter() == DebtReliefTracker.Storage.Plain
    end
  end

  describe "parse_flag/1" do
    test "true/1/yes in any case, trimmed" do
      for v <- ~w(true TRUE True 1 yes YES Yes), do: assert(E2EE.parse_flag(v))
      assert E2EE.parse_flag("  true ")
    end

    test "everything else is off" do
      for v <- [nil, "", "false", "0", "no", "on", "enabled", "truee"],
          do: refute(E2EE.parse_flag(v))
    end
  end

  describe "config/runtime.exs" do
    defp runtime_e2ee(value) do
      old = System.get_env("E2EE")
      if value, do: System.put_env("E2EE", value), else: System.delete_env("E2EE")

      on_exit(fn ->
        if old, do: System.put_env("E2EE", old), else: System.delete_env("E2EE")
      end)

      config = Config.Reader.read!("config/runtime.exs", env: :test, target: :host)
      config |> Keyword.fetch!(:debt_relief_tracker) |> Keyword.fetch!(:e2ee)
    end

    test "reads E2EE once into :e2ee" do
      assert runtime_e2ee("true") == true
      assert runtime_e2ee("1") == true
      assert runtime_e2ee("YES") == true
      assert runtime_e2ee(" Yes ") == true
      assert runtime_e2ee(nil) == false
      assert runtime_e2ee("") == false
      assert runtime_e2ee("false") == false
      assert runtime_e2ee("nope") == false
    end

    test "agrees with parse_flag/1" do
      for v <- ["true", "1", "yes", "no", "0", "", "TRUE", "maybe"] do
        assert runtime_e2ee(v) == E2EE.parse_flag(v)
      end
    end
  end

  describe "check_boot/1" do
    defp inputs(overrides) do
      Map.merge(%{enabled: false, oidc: false, host: nil, vaults_exist: false}, overrides)
    end

    test "plaintext mode with no vaults is fine" do
      assert E2EE.check_boot(inputs(%{})) == :ok
      assert E2EE.check_boot(inputs(%{host: "example.com"})) == :ok
    end

    test "E2EE with OIDC is fine on any host" do
      assert E2EE.check_boot(inputs(%{enabled: true, oidc: true, host: "debts.example.com"})) ==
               :ok
    end

    test "E2EE without OIDC warns on local hosts" do
      for host <- [nil, "", "localhost", "127.0.0.1"] do
        assert {:warn, msg} = E2EE.check_boot(inputs(%{enabled: true, host: host}))
        assert msg =~ "without OIDC"
      end
    end

    test "E2EE without OIDC on a public host is refused" do
      for host <- ["debts.example.com", "example.com", "10.0.0.5"] do
        assert {:error, msg} = E2EE.check_boot(inputs(%{enabled: true, host: host}))
        assert msg =~ "requires OIDC"
        assert msg =~ host
      end
    end

    test "E2EE off while vaults exist is refused" do
      assert {:error, msg} = E2EE.check_boot(inputs(%{vaults_exist: true}))
      assert msg =~ "E2EE is off"
    end
  end

  describe "check_boot!/0 against the real environment" do
    setup do
      old = System.get_env("PHX_HOST")

      on_exit(fn ->
        if old, do: System.put_env("PHX_HOST", old), else: System.delete_env("PHX_HOST")
      end)

      System.delete_env("PHX_HOST")
      :ok
    end

    test "passes in the default plaintext setup" do
      assert E2EE.check_boot!() == :ok
    end

    test "raises when E2EE is off but a vault row exists" do
      ws = workspace_of(oidc_user("boot"))
      {:ok, _} = Vaults.create(ws, "blob", passphrase_wrap())

      assert_raise RuntimeError, ~r/E2EE is off but encrypted vaults exist/, fn ->
        E2EE.check_boot!()
      end
    end

    test "E2EE on, no OIDC, public host raises; localhost warns" do
      enable_e2ee()
      System.put_env("PHX_HOST", "debts.example.com")
      assert_raise RuntimeError, ~r/requires OIDC/, fn -> E2EE.check_boot!() end

      System.put_env("PHX_HOST", "localhost")
      log = ExUnit.CaptureLog.capture_log(fn -> E2EE.check_boot!() end)
      assert log =~ "without OIDC"
    end

    test "E2EE on with OIDC and a public host passes" do
      enable_e2ee()
      enable_oidc()
      System.put_env("PHX_HOST", "debts.example.com")
      assert E2EE.check_boot!() == :ok
    end

    test "Boot.run/0 performs the check first" do
      enable_e2ee()
      System.put_env("PHX_HOST", "debts.example.com")
      assert_raise RuntimeError, ~r/requires OIDC/, fn -> DebtReliefTracker.Boot.run() end
    end
  end
end

defmodule DebtReliefTrackerWeb.Holo.E2EEClientBrowserTest do
  @moduledoc """
  Real-Chromium tests of the E2EE client flows (roadmap Phases 7-8): setup
  wizard, lock/unlock, recovery, methods, rollback detection, remembered
  device, tabs and idle lock. The save/sync loop and the "nothing sensitive is
  stored anywhere" test live in `E2EESyncBrowserTest`.
  """
  use DebtReliefTracker.BrowserCase

  import DebtReliefTracker.E2EEBrowser
  import DebtReliefTracker.BrowserExtras, only: [js: 2, errors: 1]

  import Ecto.Query

  alias DebtReliefTracker.BrowserCase.Driver
  alias DebtReliefTracker.E2EE.Vault
  alias DebtReliefTracker.Repo

  @pass "correct horse battery staple 77"
  @pass2 "another unusual passphrase 4242"

  setup do
    e2ee_on()
    :ok
  end

  defp unlocked(ctx, pass \\ @pass, opts \\ []) do
    ctx = open_app(ctx)
    {ctx, key} = create_vault(ctx, pass, opts)
    {ctx, key}
  end

  describe "setup wizard" do
    test "create -> lock -> unlock by passphrase; the server stores only ciphertext and wraps",
         ctx do
      ctx = open_app(ctx)
      assert_selector(ctx, "#vault-setup")
      {ctx, key} = create_vault(ctx, @pass)
      assert_selector(ctx, "#vault-created-notice")

      vault = server_vault()
      assert vault.rev == 1
      assert Enum.sort(Enum.map(vault.key_wraps, & &1.kind)) == ["passphrase", "recovery"]
      assert String.starts_with?(vault.blob, "v1.")
      refute inspect(vault.blob) =~ "schema_version"
      refute inspect(vault) =~ @pass
      refute inspect(vault) =~ String.replace(key, "-", "")

      ctx = lock(ctx)
      refute_selector(ctx, "#vault-home")
      unlock_with_passphrase(ctx, @pass)
      assert_selector(ctx, "#vault-home")
      assert errors(ctx) == []
    end

    test "validation: length, confirmation, strength; the recovery key must be acknowledged",
         ctx do
      ctx =
        ctx
        |> open_app()
        |> click("#setup-method-passphrase")
        |> fill("#setup-passphrase", "short one")
        |> fill("#setup-confirm", "short one")
        |> click("#setup-continue")
        |> assert_text("#setup-error", "at least 12")
        |> fill("#setup-passphrase", @pass)
        |> fill("#setup-confirm", @pass <> "x")
        |> click("#setup-continue")
        |> assert_text("#setup-error", "do not match")
        |> fill("#setup-passphrase", "aaaaaaaaaaaaaaaaaaaa")
        |> fill("#setup-confirm", "aaaaaaaaaaaaaaaaaaaa")
        |> click("#setup-continue")
        |> assert_text("#setup-error", "easy to guess")

      # the strength meter reacts and the offline-guessing warning is shown
      assert text(ctx, "#setup-strength-label") =~ "guessable"
      assert text(ctx, "#setup-offline-warning") =~ "offline"
      ctx = fill(ctx, "#setup-passphrase", @pass)
      assert text(ctx, "#setup-strength-label") =~ ~r/Good|Strong/
      ctx = fill(ctx, "#setup-confirm", @pass) |> click("#setup-continue")
      assert_selector(ctx, "#setup-recovery-key")

      key = recovery_key_on_screen(ctx, "#setup-recovery-key")
      assert length(String.split(key, "-")) == 14
      final = key |> String.split("-") |> List.last()

      # finish stays disabled until BOTH the checkbox and the final group are right
      assert attr(ctx, "#setup-finish", "disabled") != nil
      fill(ctx, "#setup-ack-final", final)
      assert attr(ctx, "#setup-finish", "disabled") != nil
      fill(ctx, "#setup-ack-final", "ZZZZ")
      check(ctx, "#setup-ack-saved")
      assert attr(ctx, "#setup-finish", "disabled") != nil
      fill(ctx, "#setup-ack-final", String.downcase(final))
      assert attr(ctx, "#setup-finish", "disabled") == nil
      assert server_vault_exists?() == false
      click(ctx, "#setup-finish")
      assert_selector(ctx, "#vault-home")
    end
  end

  describe "unlock" do
    test "by recovery key (any case); a typo has its own message; a wrong key is generic", ctx do
      {ctx, key} = unlocked(ctx)
      ctx = lock(ctx)

      ctx
      |> fill("#unlock-recovery-input", String.replace(key, "-", " ") |> String.downcase())
      |> click("#unlock-recovery-submit")
      |> assert_selector("#vault-home")

      ctx = lock(ctx)

      # typo: swap the first character -> checksum mismatch
      <<first::binary-size(1), rest::binary>> = key
      typo = if(first == "A", do: "B", else: "A") <> rest

      ctx
      |> fill("#unlock-recovery-input", typo)
      |> click("#unlock-recovery-submit")
      |> assert_text("#unlock-error", "valid recovery key")

      # well-formed but wrong key -> the ONE generic failure
      ctx
      |> fill("#unlock-recovery-input", foreign_recovery_key())
      |> click("#unlock-recovery-submit")
      |> assert_text("#unlock-error", "Could not unlock")

      refute_selector(ctx, "#vault-home")
    end

    test "a wrong passphrase gives one generic message, then a growing delay", ctx do
      {ctx, _} = unlocked(ctx)
      ctx = lock(ctx)

      for _ <- 1..3 do
        ctx
        |> fill("#unlock-passphrase-input", "definitely not the passphrase")
        |> click("#unlock-passphrase-submit")
        |> assert_text("#unlock-error", "Could not unlock")
        |> refute_selector("#unlock-busy")
      end

      # 4th attempt is refused locally with a wait, without touching Argon2
      ctx
      |> fill("#unlock-passphrase-input", @pass)
      |> click("#unlock-passphrase-submit")
      |> assert_selector("#unlock-delay")

      assert text(ctx, "#unlock-delay") =~ "Try again in"
      refute_selector(ctx, "#vault-home")

      # after the wait the right passphrase works and the counter resets
      Process.sleep(1200)
      click(ctx, "#unlock-passphrase-submit")
      assert_selector(ctx, "#vault-home")
    end

    test "the unlock screen offers only enrolled methods", ctx do
      {ctx, _} = unlocked(ctx)
      ctx = lock(ctx)
      assert_selector(ctx, "#unlock-passphrase-form")
      assert_selector(ctx, "#unlock-recovery-form")
      assert count(ctx, "#unlock-passkey-btn") == 0
      assert count(ctx, "#unlock-device-btn") == 0
    end

    test "a tampered blob gives the generic failure and no crash", ctx do
      {ctx, _} = unlocked(ctx)
      add_debt(ctx, "Tamper test")
      wait_status(ctx, "saved")
      ctx = lock(ctx)

      blob = server_vault().blob
      tampered = binary_part(blob, 0, byte_size(blob) - 6) <> "AAAAAA"
      Repo.update_all(from(v in Vault), set: [blob: tampered])

      # (the hash no longer matches the last seen one: acknowledge the warning first)
      unlock_with_passphrase(ctx, @pass)
      assert_selector(ctx, "#vault-rollback")
      click(ctx, "#vault-rollback-ack")
      assert_text(ctx, "#unlock-error", "Could not unlock")
      refute_selector(ctx, "#vault-home")
      assert errors(ctx) == []
    end
  end

  describe "rollback detection" do
    test "a lower revision, and the same revision with a different blob, are blocked until acknowledged",
         ctx do
      {ctx, _} = unlocked(ctx)
      add_debt(ctx, "First")
      wait_status(ctx, "saved")
      old = server_vault()
      assert old.rev == 2
      add_debt(ctx, "Second")
      wait_until(fn -> server_vault().rev == 3 end)
      wait_status(ctx, "saved")
      ctx = lock(ctx)

      # restore the older, still perfectly valid blob and revision
      Repo.update_all(from(v in Vault), set: [blob: old.blob, rev: old.rev])
      unlock_with_passphrase(ctx, @pass)
      assert_selector(ctx, "#vault-rollback")
      assert text(ctx, "#vault-rollback") =~ "rolled back"
      refute_selector(ctx, "#vault-home")

      # explicit acknowledgment continues; the old state is what is shown
      click(ctx, "#vault-rollback-ack")
      assert_selector(ctx, "#vault-home")
      assert text(ctx, "#vault-debts") =~ "First"
      refute text(ctx, "#vault-debts") =~ "Second"

      # the acknowledgment updated the record: a second visit is quiet
      ctx = lock(ctx)
      unlock_with_passphrase(ctx, @pass)
      assert_selector(ctx, "#vault-home")
      refute_selector(ctx, "#vault-rollback")
    end
  end

  describe "unlock methods" do
    test "add a passphrase, rename, remove; the last method cannot be removed", ctx do
      {ctx, _} = unlocked(ctx)
      click(ctx, "#vault-methods-btn")
      assert_selector(ctx, "#vault-methods-modal")
      assert count(ctx, "#methods-list li") == 2

      ctx
      |> fill("#methods-add-passphrase", @pass2)
      |> fill("#methods-add-confirm", @pass2)
      |> click("#methods-add-passphrase-submit")
      |> wait_for_expr("document.querySelectorAll('#methods-list li').length === 3")

      assert length(server_vault().key_wraps) == 3

      # rename
      [first | _] = server_vault().key_wraps
      click(ctx, "#wrap-rename-#{first.id}")
      fill(ctx, "#methods-rename-input", "Old laptop")
      click(ctx, "#methods-rename-save")
      assert_text(ctx, "#wrap-#{first.id}", "Old laptop")
      assert hd(server_vault().key_wraps).label == "Old laptop"

      # remove the recovery wrap and the first passphrase; the next removal is refused
      recovery = Enum.find(server_vault().key_wraps, &(&1.kind == "recovery"))
      click(ctx, "#wrap-remove-#{recovery.id}")
      wait_for_expr(ctx, "document.querySelectorAll('#methods-list li').length === 2")
      click(ctx, "#wrap-remove-#{first.id}")
      wait_for_expr(ctx, "document.querySelectorAll('#methods-list li').length === 1")
      [last] = server_vault().key_wraps
      click(ctx, "#wrap-remove-#{last.id}")
      assert_text(ctx, "#methods-status", "only unlock method")
      assert length(server_vault().key_wraps) == 1

      # the surviving passphrase is the second one
      ctx = click(ctx, "#methods-close") |> lock()
      unlock_with_passphrase(ctx, @pass)
      assert_selector(ctx, "#unlock-error")
      fill(ctx, "#unlock-passphrase-input", @pass2)
      click(ctx, "#unlock-passphrase-submit")
      assert_selector(ctx, "#vault-home")
    end

    test "change passphrase: old fails, new works, the document is untouched", ctx do
      {ctx, _} = unlocked(ctx)
      add_debt(ctx, "Keep me")
      wait_status(ctx, "saved")
      before = server_vault()

      click(ctx, "#vault-methods-btn")

      # wrong current passphrase is refused
      ctx
      |> fill("#methods-old-passphrase", "this is not the passphrase")
      |> fill("#methods-new-passphrase", @pass2)
      |> fill("#methods-new-confirm", @pass2)
      |> click("#methods-change-submit")
      |> assert_text("#methods-status", "not correct")

      ctx
      |> fill("#methods-old-passphrase", @pass)
      |> click("#methods-change-submit")
      |> assert_text("#methods-status", "Done")

      after_change = server_vault()
      assert after_change.rev == before.rev
      assert after_change.blob == before.blob, "the document is never re-encrypted"
      old_pass = Enum.find(before.key_wraps, &(&1.kind == "passphrase"))
      new_pass = Enum.filter(after_change.key_wraps, &(&1.kind == "passphrase"))
      assert [%{id: id}] = new_pass
      assert id != old_pass.id

      ctx = click(ctx, "#methods-close") |> lock()

      ctx
      |> fill("#unlock-passphrase-input", @pass)
      |> click("#unlock-passphrase-submit")
      |> assert_selector("#unlock-error")

      refute_selector(ctx, "#vault-home")

      ctx
      |> fill("#unlock-passphrase-input", @pass2)
      |> click("#unlock-passphrase-submit")
      |> assert_selector("#vault-home")

      assert text(ctx, "#vault-debts") =~ "Keep me"
    end

    test "regenerating the recovery key replaces the old one", ctx do
      {ctx, old_key} = unlocked(ctx)
      click(ctx, "#vault-methods-btn")
      click(ctx, "#methods-regen-recovery")
      assert_selector(ctx, "#methods-recovery-key")
      new_key = recovery_key_on_screen(ctx, "#methods-recovery-key")
      refute new_key == old_key
      assert attr(ctx, "#methods-recovery-confirm", "disabled") != nil

      ctx
      |> check("#methods-rec-saved")
      |> fill("#methods-rec-final", new_key |> String.split("-") |> List.last())
      |> click("#methods-recovery-confirm")
      |> assert_text("#methods-status", "Done")

      assert Enum.count(server_vault().key_wraps, &(&1.kind == "recovery")) == 1

      ctx = click(ctx, "#methods-close") |> lock()

      ctx
      |> fill("#unlock-recovery-input", old_key)
      |> click("#unlock-recovery-submit")
      |> assert_text("#unlock-error", "Could not unlock")

      ctx
      |> fill("#unlock-recovery-input", new_key)
      |> click("#unlock-recovery-submit")
      |> assert_selector("#vault-home")
    end

    test "start over: typing DELETE wipes the server vault and the local records", ctx do
      {ctx, _} = unlocked(ctx, @pass, remember: true)
      ctx = lock(ctx)
      click(ctx, "#unlock-methods-btn")
      assert_selector(ctx, "#methods-readonly")
      assert attr(ctx, "#methods-delete-confirm", "disabled") != nil
      fill(ctx, "#methods-delete-input", "delete")
      assert attr(ctx, "#methods-delete-confirm", "disabled") != nil
      fill(ctx, "#methods-delete-input", "DELETE")
      click(ctx, "#methods-delete-confirm")
      assert_selector(ctx, "#vault-setup")
      assert DebtReliefTracker.E2EE.Vaults.fetch(workspace()) == :none

      dump = storage_dump(ctx)
      assert dump["idb"]["drt-vault"]["device_keys"] == []
      assert dump["idb"]["drt-vault"]["seen"] == []

      # and a brand-new vault can be created again
      {ctx, _} = create_vault(ctx, @pass2)
      assert_selector(ctx, "#vault-home")
    end
  end

  describe "passkeys" do
    test "set up with a passkey (virtual authenticator with PRF) and unlock with it", ctx do
      ctx = open_app(ctx)
      Driver.call(ctx.driver, "webauthn_enable", %{hasPrf: true})
      # prf detection ran at mount; reload so the page sees the authenticator
      ctx = reload(ctx)
      assert_selector(ctx, "#setup-method-passkey")
      click(ctx, "#setup-method-passkey")
      click(ctx, "#setup-continue")
      assert_selector(ctx, "#setup-recovery-key")
      key = recovery_key_on_screen(ctx, "#setup-recovery-key")

      ctx
      |> check("#setup-ack-saved")
      |> fill("#setup-ack-final", key |> String.split("-") |> List.last())
      |> click("#setup-finish")
      |> assert_selector("#vault-home")

      assert Enum.sort(Enum.map(server_vault().key_wraps, & &1.kind)) == ["passkey", "recovery"]

      ctx = lock(ctx)
      assert count(ctx, "#unlock-passphrase-form") == 0
      click(ctx, "#unlock-passkey-btn")
      assert_selector(ctx, "#vault-home")

      # add a passphrase as a second method from the settings modal
      click(ctx, "#vault-methods-btn")
      fill(ctx, "#methods-add-passphrase", @pass)
      fill(ctx, "#methods-add-confirm", @pass)
      click(ctx, "#methods-add-passphrase-submit")
      wait_for_expr(ctx, "document.querySelectorAll('#methods-list li').length === 3")
    end
  end

  describe "remember this device" do
    test "reload unlocks without a method; a lock needs one click; forgetting asks again", ctx do
      {ctx, _} = unlocked(ctx, @pass, remember: true)

      # IndexedDB holds a non-extractable CryptoKey (plus the rollback record), nothing else
      dump = storage_dump(ctx)
      [%{"type" => "CryptoKey", "value" => key}] = dump["idb"]["drt-vault"]["device_keys"]
      assert key["extractable"] == false
      assert Enum.sort(key["usages"]) == ["decrypt", "encrypt"]
      [%{"value" => %{"rev" => 1, "hash" => hash}}] = dump["idb"]["drt-vault"]["seen"]
      assert is_binary(hash)

      ctx = reload(ctx)
      assert_selector(ctx, "#vault-home")
      assert text(ctx, "#vault-device-session") =~ "remembered device"

      # a remembered device session cannot manage methods
      click(ctx, "#vault-methods-btn")
      assert_selector(ctx, "#methods-readonly")
      assert attr(ctx, "#methods-add-passphrase-submit", "disabled") != nil
      assert attr(ctx, "#wrap-remove-#{hd(server_vault().key_wraps).id}", "disabled") != nil
      click(ctx, "#methods-close")

      # lock: no automatic re-unlock, but one click on the device button
      ctx = lock(ctx)
      refute_selector(ctx, "#vault-home")
      click(ctx, "#unlock-device-btn")
      assert_selector(ctx, "#vault-home")

      # forget: the next visit asks for a method again
      click(ctx, "#vault-methods-btn")
      click(ctx, "#methods-forget-device")
      wait_for_expr(ctx, "!document.querySelector('#methods-forget-device')")
      assert storage_dump(ctx)["idb"]["drt-vault"]["device_keys"] == []
      click(ctx, "#methods-close")

      ctx = reload(ctx)
      assert_selector(ctx, "#vault-unlock")
      assert count(ctx, "#unlock-device-btn") == 0
      refute_selector(ctx, "#vault-home")
    end

    test "the unlock screen's remember checkbox stores the key after a normal unlock", ctx do
      {ctx, _} = unlocked(ctx)
      assert storage_dump(ctx)["idb"]["drt-vault"]["device_keys"] == []
      ctx = lock(ctx)
      check(ctx, "#unlock-remember")
      unlock_with_passphrase(ctx, @pass)
      assert_selector(ctx, "#vault-home")
      assert [%{"type" => "CryptoKey"}] = storage_dump(ctx)["idb"]["drt-vault"]["device_keys"]
    end
  end

  describe "session" do
    test "idle auto-lock fires after the configured time and activity resets it", ctx do
      e2ee_on(idle_ms: 2500)
      {ctx, _} = unlocked(ctx)

      # activity every 0.8 s keeps it unlocked well past the timeout
      for _ <- 1..5 do
        Process.sleep(800)
        click(ctx, "#vault-sync-status")
      end

      assert_selector(ctx, "#vault-home")
      assert_selector(ctx, "#vault-unlock")
      refute_selector(ctx, "#vault-home")
    end

    test "locking one tab locks the others; unlocking is hinted to locked tabs", ctx do
      {ctx, _} = unlocked(ctx)
      ctx_b = new_tab(ctx, "b")
      assert_selector(ctx_b, "#vault-unlock")
      unlock_with_passphrase(ctx_b, @pass)
      assert_selector(ctx_b, "#vault-home")

      # lock in A -> B locks
      click(ctx, "#vault-lock-btn")
      assert_selector(ctx, "#vault-unlock")
      assert_selector(ctx_b, "#vault-unlock")
      refute_selector(ctx_b, "#vault-home")

      # unlock in B -> A (locked) is told, but stays locked (no secret was shared)
      unlock_with_passphrase(ctx_b, @pass)
      assert_selector(ctx_b, "#vault-home")
      assert_selector(ctx, "#unlock-other-tab")
      refute_selector(ctx, "#vault-home")
    end
  end

  defp server_vault_exists?, do: DebtReliefTracker.E2EE.Vaults.exists?(workspace())
end

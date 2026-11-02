defmodule DebtReliefTracker.E2EE.VaultsTest do
  use DebtReliefTracker.DataCase

  import DebtReliefTracker.E2EEHelpers

  alias DebtReliefTracker.E2EE.{KeyWrap, Vault, Vaults}

  setup do
    a = oidc_user("a")
    b = oidc_user("b")
    %{a: workspace_of(a), b: workspace_of(b)}
  end

  describe "create/3 and fetch/1" do
    test "fetch is :none before create", %{a: a} do
      assert Vaults.fetch(a) == :none
      refute Vaults.exists?(a)
    end

    test "create stores the blob and first wrap in one go", %{a: a} do
      wrap = passphrase_wrap()
      assert {:ok, %{rev: 1}} = Vaults.create(a, "v1.iv.ct", wrap)

      assert {:ok, %{rev: 1, blob: "v1.iv.ct", format_version: 1, key_wraps: [stored]}} =
               Vaults.fetch(a)

      assert stored.id == wrap.id
      assert stored.kind == "passphrase"
      assert stored.wrapped_key == wrap.wrapped_key
    end

    test "creating twice is an error and keeps the first vault", %{a: a} do
      assert {:ok, _} = Vaults.create(a, "first", passphrase_wrap())
      assert {:error, :exists} = Vaults.create(a, "second", passphrase_wrap())
      assert {:ok, %{blob: "first", key_wraps: [_]}} = Vaults.fetch(a)
    end

    test "an invalid first wrap rolls the whole create back", %{a: a} do
      assert {:error, {:invalid, errors}} =
               Vaults.create(a, "blob", passphrase_wrap(%{kind: "bogus"}))

      assert Map.has_key?(errors, :kind)
      assert Vaults.fetch(a) == :none
    end

    test "inspect never prints the vault payload", %{a: a} do
      {:ok, _} = Vaults.create(a, "SECRETBLOB", passphrase_wrap())
      vault = Repo.get!(Vault, a.id)
      wrap = Repo.one!(KeyWrap)
      refute inspect(vault) =~ "SECRETBLOB"
      refute inspect(wrap) =~ wrap.wrapped_key
      refute inspect(wrap) =~ wrap.salt
      refute inspect(wrap) =~ "memoryKiB"
    end
  end

  describe "create/3 with several wraps" do
    test "stores all of them atomically", %{a: a} do
      w1 = passphrase_wrap()
      w2 = passphrase_wrap(%{kind: "recovery", label: nil, kdf_params: nil, salt: nil})
      assert {:ok, %{rev: 1}} = Vaults.create(a, "v1.iv.ct", [w1, w2])
      assert {:ok, %{key_wraps: wraps}} = Vaults.fetch(a)
      assert Enum.sort(Enum.map(wraps, & &1.id)) == Enum.sort([w1.id, w2.id])
    end

    test "one invalid wrap rolls everything back", %{a: a} do
      assert {:error, {:invalid, _}} =
               Vaults.create(a, "v1.iv.ct", [passphrase_wrap(), passphrase_wrap(%{kind: "x"})])

      assert Vaults.fetch(a) == :none
      assert {:error, {:invalid, _}} = Vaults.create(a, "v1.iv.ct", [])
    end
  end

  describe "rename_key_wrap/3" do
    test "changes only the label", %{a: a} do
      w = passphrase_wrap()
      {:ok, _} = Vaults.create(a, "b", w)
      assert {:ok, renamed} = Vaults.rename_key_wrap(a, w.id, "Laptop")
      assert renamed.label == "Laptop"
      assert renamed.wrapped_key == w.wrapped_key
      assert {:ok, %{key_wraps: [%{label: "Laptop"}]}} = Vaults.fetch(a)
    end

    test "unknown ids, other workspaces and long labels are refused", %{a: a, b: b} do
      w = passphrase_wrap()
      {:ok, _} = Vaults.create(a, "b", w)
      assert {:error, :not_found} = Vaults.rename_key_wrap(a, Ecto.UUID.generate(), "x")
      assert {:error, :not_found} = Vaults.rename_key_wrap(a, "nope", "x")
      assert {:error, :not_found} = Vaults.rename_key_wrap(b, w.id, "stolen")

      assert {:error, {:invalid, %{label: _}}} =
               Vaults.rename_key_wrap(a, w.id, String.duplicate("x", 101))

      assert {:ok, %{key_wraps: [%{label: "pass"}]}} = Vaults.fetch(a)
    end
  end

  describe "size limits and shape" do
    test "blob over 5 MB is :too_large", %{a: a} do
      big = :binary.copy("x", Vaults.max_blob_bytes() + 1)
      assert {:error, :too_large} = Vaults.create(a, big, passphrase_wrap())
      assert Vaults.fetch(a) == :none

      {:ok, _} = Vaults.create(a, "ok", passphrase_wrap())
      assert {:error, :too_large} = Vaults.save(a, 1, big)
      assert {:ok, %{rev: 1, blob: "ok"}} = Vaults.fetch(a)
    end

    test "blob of exactly 5 MB is accepted", %{a: a} do
      assert {:ok, _} =
               Vaults.create(a, :binary.copy("x", Vaults.max_blob_bytes()), passphrase_wrap())
    end

    test "oversized wrap fields are :too_large", %{a: a} do
      assert {:error, :too_large} =
               Vaults.create(a, "b", passphrase_wrap(%{salt: b64u(129)}))

      {:ok, _} = Vaults.create(a, "b", passphrase_wrap())

      assert {:error, :too_large} =
               Vaults.add_key_wrap(a, passkey_wrap(%{credential_id: b64u(1025)}))

      assert {:error, :too_large} =
               Vaults.add_key_wrap(a, passkey_wrap(%{wrapped_key: "v1.a." <> b64u(1100)}))
    end

    test "an empty blob is rejected", %{a: a} do
      assert {:error, {:invalid, %{blob: _}}} = Vaults.create(a, "", passphrase_wrap())
    end

    test "kind and shape are validated", %{a: a} do
      {:ok, _} = Vaults.create(a, "b", passphrase_wrap())

      for bad <- [
            passkey_wrap(%{kind: "password"}),
            passkey_wrap(%{credential_id: nil}),
            passkey_wrap(%{wrapped_key: "not-an-envelope"}),
            passkey_wrap(%{credential_id: "has spaces!"}),
            passphrase_wrap(%{salt: nil}),
            passphrase_wrap(%{id: "not-a-uuid"})
          ] do
        assert {:error, {:invalid, _}} = Vaults.add_key_wrap(a, bad)
      end

      assert {:ok, %{key_wraps: [_]}} = Vaults.fetch(a)
    end

    test "unknown attrs (e.g. a smuggled workspace_id) are ignored", %{a: a, b: b} do
      {:ok, _} = Vaults.create(a, "b", passphrase_wrap())
      {:ok, _} = Vaults.create(b, "b", passphrase_wrap())

      assert {:ok, wrap} = Vaults.add_key_wrap(a, Map.put(passkey_wrap(), :workspace_id, b.id))
      assert wrap.workspace_id == a.id
    end

    test "duplicate passkey credential in one workspace is rejected", %{a: a} do
      {:ok, _} = Vaults.create(a, "b", passphrase_wrap())
      first = passkey_wrap()
      assert {:ok, _} = Vaults.add_key_wrap(a, first)

      assert {:error, _} =
               Vaults.add_key_wrap(a, passkey_wrap(%{credential_id: first.credential_id}))

      assert {:ok, %{key_wraps: wraps}} = Vaults.fetch(a)
      assert length(wraps) == 2
    end

    test "adding a wrap without a vault is :not_found", %{a: a} do
      assert {:error, :not_found} = Vaults.add_key_wrap(a, passkey_wrap())
    end

    test "a vault is capped at 3 passphrase wraps (other kinds unaffected)", %{a: a} do
      {:ok, _} = Vaults.create(a, "b", passphrase_wrap())
      for _ <- 2..3, do: {:ok, _} = Vaults.add_key_wrap(a, passphrase_wrap())
      assert {:error, :too_many_passphrase_wraps} = Vaults.add_key_wrap(a, passphrase_wrap())
      assert {:ok, _} = Vaults.add_key_wrap(a, passkey_wrap())
      assert {:ok, %{key_wraps: wraps}} = Vaults.fetch(a)
      assert Enum.count(wraps, &(&1.kind == "passphrase")) == 3
    end

    test "create refuses a fourth passphrase wrap", %{a: a} do
      wraps = for _ <- 1..4, do: passphrase_wrap()
      assert {:error, :too_many_passphrase_wraps} = Vaults.create(a, "b", wraps)
      assert :none = Vaults.fetch(a)
    end

    test "a workspace is capped at 20 wraps", %{a: a} do
      {:ok, _} = Vaults.create(a, "b", passphrase_wrap())
      for _ <- 2..20, do: {:ok, _} = Vaults.add_key_wrap(a, passkey_wrap())
      assert {:error, :too_many_wraps} = Vaults.add_key_wrap(a, passkey_wrap())
    end
  end

  describe "save/3 compare-and-swap" do
    setup %{a: a} do
      {:ok, _} = Vaults.create(a, "rev1", passphrase_wrap())
      :ok
    end

    test "advances rev when base_rev matches", %{a: a} do
      assert {:ok, %{rev: 2}} = Vaults.save(a, 1, "rev2")
      assert {:ok, %{rev: 3}} = Vaults.save(a, 2, "rev3")
      assert {:ok, %{rev: 3, blob: "rev3"}} = Vaults.fetch(a)
    end

    test "a stale base_rev conflicts with the server's current state", %{a: a} do
      {:ok, _} = Vaults.save(a, 1, "rev2")
      assert {:conflict, %{rev: 2, blob: "rev2"}} = Vaults.save(a, 1, "loser")
      assert {:ok, %{rev: 2, blob: "rev2"}} = Vaults.fetch(a)
    end

    test "a future base_rev conflicts too", %{a: a} do
      assert {:conflict, %{rev: 1, blob: "rev1"}} = Vaults.save(a, 5, "x")
    end

    test "saving without a vault is :not_found", %{b: b} do
      assert {:error, :not_found} = Vaults.save(b, 1, "x")
    end

    test "two concurrent saves from the same base_rev: exactly one wins", %{a: a} do
      results =
        ["from-one", "from-two"]
        |> Enum.map(fn blob -> Task.async(fn -> {blob, Vaults.save(a, 1, blob)} end) end)
        |> Task.await_many(10_000)

      assert [{winner_blob, {:ok, %{rev: 2}}}] =
               Enum.filter(results, &match?({_, {:ok, _}}, &1))

      assert [{_, {:conflict, %{rev: 2, blob: ^winner_blob}}}] =
               Enum.filter(results, &match?({_, {:conflict, _}}, &1))

      assert {:ok, %{rev: 2, blob: ^winner_blob}} = Vaults.fetch(a)
    end
  end

  describe "key wraps" do
    setup %{a: a} do
      first = passphrase_wrap()
      {:ok, _} = Vaults.create(a, "b", first)
      %{first: first}
    end

    test "add then remove", %{a: a, first: first} do
      {:ok, added} = Vaults.add_key_wrap(a, passkey_wrap())
      assert {:ok, %{key_wraps: [_, _]}} = Vaults.fetch(a)

      assert :ok = Vaults.remove_key_wrap(a, first.id)
      assert {:ok, %{key_wraps: [only]}} = Vaults.fetch(a)
      assert only.id == added.id
    end

    test "the last wrap cannot be removed", %{a: a, first: first} do
      assert {:error, :last_wrap} = Vaults.remove_key_wrap(a, first.id)
      assert {:ok, %{key_wraps: [_]}} = Vaults.fetch(a)
    end

    test "unknown and malformed ids are :not_found", %{a: a} do
      {:ok, _} = Vaults.add_key_wrap(a, passkey_wrap())
      assert {:error, :not_found} = Vaults.remove_key_wrap(a, Ecto.UUID.generate())
      assert {:error, :not_found} = Vaults.remove_key_wrap(a, "nope")
      assert {:ok, %{key_wraps: [_, _]}} = Vaults.fetch(a)
    end
  end

  describe "delete_vault/1" do
    test "removes the vault and every wrap", %{a: a} do
      {:ok, _} = Vaults.create(a, "b", passphrase_wrap())
      {:ok, _} = Vaults.add_key_wrap(a, passkey_wrap())

      assert :ok = Vaults.delete_vault(a)
      assert Vaults.fetch(a) == :none
      assert Repo.aggregate(KeyWrap, :count) == 0
    end

    test "deleting a missing vault is :not_found", %{a: a} do
      assert {:error, :not_found} = Vaults.delete_vault(a)
    end

    test "after deleting, a fresh vault can be created", %{a: a} do
      {:ok, _} = Vaults.create(a, "b", passphrase_wrap())
      :ok = Vaults.delete_vault(a)
      assert {:ok, %{rev: 1}} = Vaults.create(a, "again", passphrase_wrap())
    end
  end

  describe "workspace isolation" do
    setup %{a: a, b: b} do
      a_wrap = passphrase_wrap()
      {:ok, _} = Vaults.create(a, "A-SECRET", a_wrap)
      {:ok, extra} = Vaults.add_key_wrap(a, passkey_wrap())
      {:ok, _} = Vaults.create(b, "B-BLOB", passphrase_wrap())
      %{a_wrap: a_wrap, a_extra: extra}
    end

    test "B only ever sees B's data", %{b: b} do
      assert {:ok, %{blob: "B-BLOB", key_wraps: [_]}} = Vaults.fetch(b)
    end

    test "B cannot save into or conflict-read A's vault", %{a: a, b: b} do
      assert {:ok, %{rev: 2}} = Vaults.save(b, 1, "B-NEW")
      assert {:ok, %{rev: 1, blob: "A-SECRET"}} = Vaults.fetch(a)
      # a conflict for B leaks only B's state
      assert {:conflict, %{blob: "B-NEW"}} = Vaults.save(b, 1, "x")
    end

    test "B cannot remove A's wraps even by guessing ids", %{
      a: a,
      b: b,
      a_wrap: a_wrap,
      a_extra: extra
    } do
      {:ok, _} = Vaults.add_key_wrap(b, passkey_wrap())

      assert {:error, :not_found} = Vaults.remove_key_wrap(b, a_wrap.id)
      assert {:error, :not_found} = Vaults.remove_key_wrap(b, extra.id)
      assert {:ok, %{key_wraps: [_, _]}} = Vaults.fetch(a)
    end

    test "B cannot claim A's wrap id as its own", %{b: b, a_wrap: a_wrap} do
      assert {:error, _} = Vaults.add_key_wrap(b, passkey_wrap(%{id: a_wrap.id}))
    end

    test "deleting B's vault leaves A's", %{a: a, b: b} do
      :ok = Vaults.delete_vault(b)
      assert {:ok, %{blob: "A-SECRET", key_wraps: [_, _]}} = Vaults.fetch(a)
    end

    test "deleting the workspace cascades", %{a: a} do
      Repo.delete!(a)
      assert Repo.aggregate(Vault, :count) == 1
      assert Repo.aggregate(KeyWrap, :count) == 1
    end
  end
end

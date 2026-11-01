defmodule DebtReliefTrackerWeb.Holo.MigrationFlowTest do
  use ExUnit.Case, async: true

  alias DebtReliefTracker.VaultDoc
  alias DebtReliefTrackerWeb.Holo.MigrationFlow, as: Flow

  defp debt(id, pos, name, balance) do
    %{
      id: id,
      name: name,
      type: "installment",
      status: "active",
      balance: balance,
      original_balance: balance,
      apr_bp: 1999,
      fixed_payment: 5_000,
      minimum_payment_floor: nil,
      minimum_payment_rate_bp: nil,
      credit_limit: nil,
      exclude_from_plan: false,
      statement_balance: nil,
      statement_date: nil,
      position: pos,
      due_day: nil,
      auto_log_mode: "off",
      last_due_handled_on: nil,
      paid_off_at: nil,
      updated_at: "2026-10-01T00:00:00Z"
    }
  end

  defp payment(id, debt_id, amount, day) do
    %{
      id: id,
      debt_id: debt_id,
      amount: amount,
      principal_portion: amount - 100,
      interest_portion: 100,
      paid_on: day,
      note: "note #{id}",
      logged_by_user_id: nil,
      inserted_at: "2026-10-0#{day |> String.last()}T10:00:00Z",
      updated_at: "2026-10-0#{day |> String.last()}T10:00:00Z"
    }
  end

  defp snapshot do
    %{
      schema_version: 1,
      settings: %{
        monthly_budget: 150_000,
        currency: "USD",
        budget_mode: "total",
        retirement_onboarding_dismissed: false,
        updated_at: "2026-10-01T00:00:00Z"
      },
      debts: [debt("d1", 0, "Visa", 100_000), debt("d2", 1, "Car", 900_000)],
      payments: [
        payment("p2", "d2", 20_000, "2026-10-02"),
        payment("p1", "d1", 10_000, "2026-10-01"),
        payment("p3", "d1", 5_000, "2026-10-03")
      ],
      activity: [
        %{
          id: "a2",
          action: "payment_logged",
          debt_id: "d1",
          user_id: nil,
          metadata: %{"amount" => 5_000},
          inserted_at: "2026-10-03T10:00:00Z"
        },
        %{
          id: "a1",
          action: "debt_added",
          debt_id: "d1",
          user_id: nil,
          metadata: %{"name" => "Visa"},
          inserted_at: "2026-10-01T10:00:00Z"
        }
      ],
      retirement_profiles: []
    }
  end

  # What the page sees after build -> encode -> upload -> download -> decode.
  defp redownloaded_view(snap) do
    {:ok, doc} =
      snap
      |> VaultDoc.from_snapshot("2026-11-01T00:00:00Z")
      |> VaultDoc.encode()
      |> VaultDoc.decode()

    VaultDoc.view(doc)
  end

  defp export_reply(snap, opts \\ []) do
    %{
      ok: true,
      snapshot: snap,
      digest: Keyword.get(opts, :digest, "digest-1"),
      members: Keyword.get(opts, :members, []),
      pending_invitations: Keyword.get(opts, :pending, 0)
    }
  end

  defp run(state, events) do
    Enum.reduce(events, {state, []}, fn ev, {s, acc} ->
      {s, effects} = Flow.apply(s, ev)
      {s, acc ++ effects}
    end)
  end

  defp to_needs_migration(opts) do
    {s, _} = Flow.start(Flow.new())

    {s, _} =
      run(s, [
        {:status_result, %{ok: true, status: :plaintext_only, owner: true}},
        {:export_result, export_reply(snapshot(), opts)}
      ])

    s
  end

  defp to_verifying(opts \\ []) do
    s = to_needs_migration(opts)

    {s, _} =
      if Flow.members?(s) do
        run(s, [:begin, {:confirm_members, true}, :vault_created])
      else
        run(s, [:begin, :vault_created])
      end

    s
  end

  defp finalize_effects(effects),
    do: for({:command, :migration_finalize, _} = e <- effects, do: e)

  describe "verify/2" do
    test "the real roundtrip passes, even though stamps are restamped" do
      assert :ok = Flow.verify(snapshot(), redownloaded_view(snapshot()))
    end

    test "is order-insensitive" do
      view = redownloaded_view(snapshot())
      reordered = %{view | payments: Enum.reverse(view.payments), debts: Enum.reverse(view.debts)}
      assert :ok = Flow.verify(snapshot(), reordered)
    end

    test "string vs atom keys in metadata are equivalent" do
      view = redownloaded_view(snapshot())

      activity =
        Enum.map(
          view.activity,
          &%{&1 | metadata: for({k, v} <- &1.metadata, into: %{}, do: {String.to_atom(k), v})}
        )

      assert :ok = Flow.verify(snapshot(), %{view | activity: activity})
    end

    test "every kind of difference is a mismatch" do
      snap = snapshot()
      view = redownloaded_view(snap)
      bad = {:error, :verification_mismatch}

      [p | rest] = view.payments

      cases = %{
        "dropped payment" => %{view | payments: rest},
        "changed cent" => %{view | payments: [%{p | amount: p.amount + 1} | rest]},
        "changed principal" => %{
          view
          | payments: [%{p | principal_portion: p.principal_portion + 1} | rest]
        },
        "renamed debt" => %{view | debts: Enum.map(view.debts, &%{&1 | name: &1.name <> "!"})},
        "changed balance" => %{
          view
          | debts: Enum.map(view.debts, &%{&1 | balance: &1.balance - 1})
        },
        "changed note" => %{view | payments: [%{p | note: "other"} | rest]},
        "changed apr" => %{view | debts: Enum.map(view.debts, &%{&1 | apr_bp: 1})},
        "extra activity" => %{
          view
          | activity: [%{hd(view.activity) | id: "a-extra"} | view.activity]
        },
        "changed activity metadata" => %{
          view
          | activity: Enum.map(view.activity, &%{&1 | metadata: %{"x" => 1}})
        },
        "changed activity action" => %{
          view
          | activity: Enum.map(view.activity, &%{&1 | action: "other"})
        },
        "extra payment" => %{view | payments: [%{p | id: "p-extra"} | view.payments]},
        "swapped id" => %{view | payments: [%{p | id: "p-other"} | rest]},
        "duplicate id" => %{view | payments: [p, p | rest]},
        "missing debt" => %{view | debts: tl(view.debts)},
        "extra retirement profile" => %{view | retirement_profiles: [%{id: "r1"}]},
        "changed budget" => %{view | settings: %{view.settings | monthly_budget: 1}},
        "changed currency" => %{view | settings: %{view.settings | currency: "EUR"}},
        "empty doc" =>
          redownloaded_view(%{
            snap
            | debts: [],
              payments: [],
              activity: [],
              settings:
                Map.delete(snap.settings, :updated_at)
                |> Map.put(:updated_at, "2026-10-01T00:00:00Z")
          }),
        "missing collection" => Map.delete(view, :payments),
        "not a map" => nil
      }

      for {name, v} <- cases do
        assert Flow.verify(snap, v) == bad, "expected mismatch for #{name}"
      end
    end
  end

  describe "happy path" do
    test "no other members" do
      {s, effects} = Flow.start(Flow.new())
      assert effects == [{:command, :migration_status}]

      {s, effects} =
        Flow.apply(s, {:status_result, %{ok: true, status: :plaintext_only, owner: true}})

      assert effects == [{:command, :migration_export}]

      {s, []} = Flow.apply(s, {:export_result, export_reply(snapshot())})
      assert s.step == :needs_migration

      {s, effects} = Flow.apply(s, :begin)
      assert s.step == :setting_up
      assert effects == [{:build_vault, snapshot()}]

      {s, effects} = Flow.apply(s, :vault_created)
      assert s.step == :verifying
      assert effects == [{:redownload_vault}]

      {s, effects} = Flow.apply(s, {:vault_downloaded, {:ok, redownloaded_view(snapshot())}})
      assert s.step == :finalizing

      assert effects == [
               {:command, :migration_finalize,
                %{digest: "digest-1", confirm_remove_members: false}}
             ]

      {s, []} = Flow.apply(s, {:finalize_result, %{ok: true, deleted: %{}}})
      assert s.step == :done
      assert Flow.terminal?(s)
    end

    test "already_clean finalize also completes" do
      s = to_verifying()
      {s, _} = Flow.apply(s, {:vault_downloaded, {:ok, redownloaded_view(snapshot())}})
      {s, _} = Flow.apply(s, {:finalize_result, %{ok: true, already_clean: true}})
      assert s.step == :done
    end
  end

  describe "members" do
    test "cannot skip confirmation; false stays put; true proceeds" do
      s = to_needs_migration(members: [%{display_name: "B", email: "b@x"}])
      {s, []} = Flow.apply(s, :begin)
      assert s.step == :confirming_members

      for ev <- [
            :vault_created,
            {:vault_downloaded, {:ok, redownloaded_view(snapshot())}},
            :begin
          ] do
        assert {^s, []} = Flow.apply(s, ev)
      end

      assert {^s, []} = Flow.apply(s, {:confirm_members, false})
      assert {^s, []} = Flow.apply(s, {:confirm_members, nil})
      assert {^s, []} = Flow.apply(s, {:confirm_members, "true"})

      {s, [{:build_vault, _}]} = Flow.apply(s, {:confirm_members, true})
      assert s.step == :setting_up
      {s, _} = Flow.apply(s, :vault_created)
      {_s, effects} = Flow.apply(s, {:vault_downloaded, {:ok, redownloaded_view(snapshot())}})

      assert effects == [
               {:command, :migration_finalize,
                %{digest: "digest-1", confirm_remove_members: true}}
             ]
    end

    test "pending invitations alone need confirmation" do
      s = to_needs_migration(pending: 2)
      assert {%{step: :confirming_members}, []} = Flow.apply(s, :begin)
    end

    test "members_present at finalize is a terminal failure" do
      s = to_verifying()
      {s, _} = Flow.apply(s, {:vault_downloaded, {:ok, redownloaded_view(snapshot())}})
      {s, []} = Flow.apply(s, {:finalize_result, %{ok: false, error: :members_present}})
      assert {s.step, s.reason} == {:failed, :members_present}
      assert Flow.terminal?(s)
    end
  end

  describe "finalize failures" do
    test "digest changed: re-export, rebuild the vault, verify the NEW export, finalize its digest" do
      s = to_verifying()
      {s, _} = Flow.apply(s, {:vault_downloaded, {:ok, redownloaded_view(snapshot())}})
      {s, effects} = Flow.apply(s, {:finalize_result, %{ok: false, error: :changed}})
      assert s.step == :re_exporting
      assert s.verified_digest == nil
      assert effects == [{:command, :migration_export}]

      newer = %{
        snapshot()
        | payments: [payment("p9", "d1", 700, "2026-10-04") | snapshot().payments]
      }

      {s, effects} = Flow.apply(s, {:export_result, export_reply(newer, digest: "digest-2")})
      assert s.step == :setting_up
      assert effects == [{:rebuild_vault, newer}]

      {s, [{:redownload_vault}]} = Flow.apply(s, :vault_created)

      # the OLD vault contents no longer verify
      {failed, []} = Flow.apply(s, {:vault_downloaded, {:ok, redownloaded_view(snapshot())}})
      assert failed.reason == :verification_mismatch

      {s, effects} = Flow.apply(s, {:vault_downloaded, {:ok, redownloaded_view(newer)}})

      assert effects == [
               {:command, :migration_finalize,
                %{digest: "digest-2", confirm_remove_members: false}}
             ]

      assert s.step == :finalizing
    end

    test "changed rounds are bounded" do
      s = to_verifying()

      final =
        Enum.reduce(1..4, s, fn _, s ->
          {s, _} = Flow.apply(s, {:vault_downloaded, {:ok, redownloaded_view(snapshot())}})
          {s, _} = Flow.apply(s, {:finalize_result, %{ok: false, error: :changed}})

          case s.step do
            :re_exporting ->
              {s, _} = Flow.apply(s, {:export_result, export_reply(snapshot())})
              {s, _} = Flow.apply(s, :vault_created)
              s

            _ ->
              s
          end
        end)

      assert {final.step, final.reason} == {:failed, :changed}
    end

    test "busy retries with backoff, bounded, same digest" do
      s = to_verifying()
      {s, _} = Flow.apply(s, {:vault_downloaded, {:ok, redownloaded_view(snapshot())}})
      busy = {:finalize_result, %{ok: false, error: :busy}}
      fin = {:command, :migration_finalize, %{digest: "digest-1", confirm_remove_members: false}}

      {s, [{:retry_after, 1_000, ^fin}]} = Flow.apply(s, busy)
      {s, [{:retry_after, 3_000, ^fin}]} = Flow.apply(s, busy)
      {s, [{:retry_after, 9_000, ^fin}]} = Flow.apply(s, busy)
      assert s.step == :finalizing
      {s, []} = Flow.apply(s, busy)
      assert {s.step, s.reason} == {:failed, :busy}
      assert s.verified_digest == nil

      # a retry re-verifies; it never re-sends finalize by itself
      assert {%{step: :failed}, []} = Flow.apply(s, :retry)
    end

    test "busy then success" do
      s = to_verifying()
      {s, _} = Flow.apply(s, {:vault_downloaded, {:ok, redownloaded_view(snapshot())}})
      {s, _} = Flow.apply(s, {:finalize_result, %{ok: false, error: :busy}})
      {s, []} = Flow.apply(s, {:finalize_result, %{ok: true}})
      assert s.step == :done
    end
  end

  describe "verification failures block finalize" do
    test "mismatch, decode error and bad replies never emit finalize" do
      snap = snapshot()
      view = redownloaded_view(snap)

      bad_events = [
        {:vault_downloaded, {:ok, %{view | payments: tl(view.payments)}}},
        {:vault_downloaded, {:ok, %{view | debts: Enum.map(view.debts, &%{&1 | name: "zzz"})}}},
        {:vault_downloaded,
         {:ok, redownloaded_view(%{snap | debts: [], payments: [], activity: []})}},
        {:vault_downloaded, {:error, :invalid}},
        {:vault_downloaded, :nonsense},
        {:vault_downloaded, {:ok, nil}}
      ]

      for ev <- bad_events do
        {s, effects} = Flow.apply(to_verifying(), ev)
        assert {s.step, s.reason} == {:failed, :verification_mismatch}
        assert finalize_effects(effects) == []
        assert s.verified_digest == nil
        # events that would only be valid in :finalizing do nothing now
        assert {^s, []} = Flow.apply(s, {:finalize_result, %{ok: true}})
      end
    end

    test "retry re-downloads; rebuild is bounded" do
      {s, _} = Flow.apply(to_verifying(), {:vault_downloaded, {:error, :invalid}})
      {r, [{:redownload_vault}]} = Flow.apply(s, :retry)
      assert r.step == :verifying

      {s1, [{:rebuild_vault, _}]} = Flow.apply(s, :rebuild)
      assert s1.step == :setting_up
      {s1, _} = Flow.apply(s1, :vault_created)
      {s1, _} = Flow.apply(s1, {:vault_downloaded, {:error, :invalid}})
      {s2, [{:rebuild_vault, _}]} = Flow.apply(s1, :rebuild)
      {s2, _} = Flow.apply(s2, :vault_created)
      {s2, _} = Flow.apply(s2, {:vault_downloaded, {:error, :invalid}})
      assert {_, []} = Flow.apply(s2, :rebuild)
    end
  end

  describe "terminal states" do
    test "export errors" do
      for reason <- [:forbidden, :already_encrypted, :nothing_to_migrate, :too_large] do
        {s, _} = Flow.start(Flow.new())

        {s, _} =
          Flow.apply(s, {:status_result, %{ok: true, status: :plaintext_only, owner: true}})

        {s, []} = Flow.apply(s, {:export_result, %{ok: false, error: reason}})
        assert {s.step, s.reason} == {:failed, reason}
        assert Flow.terminal?(s)
        assert {^s, []} = Flow.apply(s, :retry)
      end
    end

    test "non-owner is forbidden; vault_only and empty have nothing to migrate" do
      {s, _} =
        Flow.apply(
          Flow.new(),
          {:status_result, %{ok: true, status: :plaintext_only, owner: false}}
        )

      assert {s.step, s.reason} == {:failed, :forbidden}

      for st <- [:vault_only, :empty] do
        {s, []} = Flow.apply(Flow.new(), {:status_result, %{ok: true, status: st, owner: true}})
        assert {s.step, s.reason} == {:failed, :nothing_to_migrate}
      end
    end

    test "transient rate limit on export is retryable" do
      {s, _} =
        Flow.apply(
          Flow.new(),
          {:status_result, %{ok: true, status: :plaintext_only, owner: true}}
        )

      {s, []} = Flow.apply(s, {:export_result, %{ok: false, error: :rate_limited}})
      refute Flow.terminal?(s)
      assert {%{step: :checking}, [{:command, :migration_export}]} = Flow.apply(s, :retry)
    end
  end

  describe "resume after reload (status :both)" do
    test "re-exports and resumes at :verifying" do
      {s, _} = Flow.apply(Flow.new(), {:status_result, %{ok: true, status: :both, owner: true}})
      {s, effects} = Flow.apply(s, {:export_result, export_reply(snapshot())})
      assert s.step == :verifying
      assert effects == [{:redownload_vault}]
      {s, effects} = Flow.apply(s, {:vault_downloaded, {:ok, redownloaded_view(snapshot())}})
      assert s.step == :finalizing
      assert length(finalize_effects(effects)) == 1
    end

    test "with members, confirmation still required, then verifying" do
      {s, _} = Flow.apply(Flow.new(), {:status_result, %{ok: true, status: :both, owner: true}})
      {s, []} = Flow.apply(s, {:export_result, export_reply(snapshot(), pending: 1)})
      assert s.step == :confirming_members
      {s, [{:redownload_vault}]} = Flow.apply(s, {:confirm_members, true})
      assert s.step == :verifying
    end

    test "a stale vault fails verification and can be rebuilt" do
      {s, _} = Flow.apply(Flow.new(), {:status_result, %{ok: true, status: :both, owner: true}})
      newer = %{snapshot() | debts: [debt("d1", 0, "Visa", 1) | tl(snapshot().debts)]}
      {s, _} = Flow.apply(s, {:export_result, export_reply(newer)})
      {s, effects} = Flow.apply(s, {:vault_downloaded, {:ok, redownloaded_view(snapshot())}})
      assert s.reason == :verification_mismatch
      assert finalize_effects(effects) == []
      assert {%{step: :setting_up}, [{:rebuild_vault, ^newer}]} = Flow.apply(s, :rebuild)
    end
  end

  describe "property: :finalizing is only reachable through a successful verify" do
    test "random event sequences (seeded)" do
      :rand.seed(:exsss, {101, 202, 303})
      snap = snapshot()
      good = redownloaded_view(snap)
      newer = %{snap | payments: tl(snap.payments)}

      events = [
        {:status_result, %{ok: true, status: :plaintext_only, owner: true}},
        {:status_result, %{ok: true, status: :both, owner: true}},
        {:status_result, %{ok: true, status: :empty, owner: true}},
        {:status_result, %{ok: true, status: :plaintext_only, owner: false}},
        {:export_result, export_reply(snap)},
        {:export_result, export_reply(newer, digest: "digest-2", pending: 1)},
        {:export_result, %{ok: false, error: :forbidden}},
        {:export_result, %{ok: false, error: :failed}},
        :begin,
        {:confirm_members, true},
        {:confirm_members, false},
        :vault_created,
        :vault_failed,
        {:vault_downloaded, {:ok, good}},
        {:vault_downloaded, {:ok, redownloaded_view(newer)}},
        {:vault_downloaded, {:ok, %{good | payments: tl(good.payments)}}},
        {:vault_downloaded, {:error, :invalid}},
        {:finalize_result, %{ok: true}},
        {:finalize_result, %{ok: false, error: :changed}},
        {:finalize_result, %{ok: false, error: :busy}},
        {:finalize_result, %{ok: false, error: :members_present}},
        {:finalize_result, %{ok: false, error: :other}},
        :retry,
        :rebuild,
        :garbage
      ]

      n = length(events)
      reached = :counters.new(1, [])

      for _run <- 1..400 do
        Enum.reduce(1..40, Flow.new(), fn _, s ->
          ev = Enum.at(events, :rand.uniform(n) - 1)
          {s2, effects} = Flow.apply(s, ev)

          if s2.step == :finalizing and s.step != :finalizing do
            :counters.add(reached, 1, 1)
            assert s.step == :verifying
            assert {:vault_downloaded, {:ok, view}} = ev
            assert Flow.verify(s.export.snapshot, view) == :ok
            assert s2.verified_digest == s.export.digest
          end

          finals = finalize_effects(effects)

          effects
          |> Enum.flat_map(fn
            {:retry_after, _, e} -> [e]
            e -> [e]
          end)
          |> Enum.each(fn
            {:command, :migration_finalize, p} ->
              assert s2.step == :finalizing
              assert p.digest == s2.verified_digest
              assert p.digest == s2.export.digest

            _ ->
              :ok
          end)

          if s2.step != :finalizing, do: assert(s2.verified_digest == nil)
          if s2.step == :done, do: assert(s.step in [:finalizing, :done])
          _ = finals
          s2
        end)
      end

      # the walk is not vacuous
      assert :counters.get(reached, 1) > 0
    end
  end

  describe "vault creation failure" do
    test "a failed vault creation can be retried, and verification still gates finalize" do
      s = to_needs_migration([])
      {s, [{:build_vault, snap}]} = Flow.apply(s, :begin)
      assert s.step == :setting_up

      {s, []} = Flow.apply(s, :vault_failed)
      assert s.step == :failed
      assert s.reason == :vault_failed
      refute Flow.terminal?(s)

      # :retry rebuilds the vault from the same export (nothing was deleted).
      {s, effects} = Flow.apply(s, :retry)
      assert s.step == :setting_up
      assert effects == [{:build_vault, snap}]

      # It still must go through download + verify before any finalize effect.
      {s, effects} = Flow.apply(s, :vault_created)
      assert s.step == :verifying
      assert effects == [{:redownload_vault}]
      refute Enum.any?(effects, &match?({:command, :migration_finalize, _}, &1))
    end
  end
end

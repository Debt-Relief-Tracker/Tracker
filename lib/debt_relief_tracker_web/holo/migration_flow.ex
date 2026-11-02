defmodule DebtReliefTrackerWeb.Holo.MigrationFlow do
  @moduledoc """
  Pure, client-safe state machine for the one-time plaintext -> vault
  migration (ADR 0007, "Production rollout" / "Migration server contract").
  No Decimal/Date/Regex/floats/Ecto, no I/O: `apply/2` returns
  `{state, effects}` where effects are plain data the page must perform (the
  UI step wires them to `MigrationGate` commands and the vault wizard). Late
  or out-of-order events are ignored (`{state, []}`).

  ## State diagram

      :checking --status plaintext_only--> (export) --> :needs_migration
      :checking --status both--> (export, resume) --> :verifying
                                                      (or :confirming_members)
      :checking --vault_only | empty--> :failed(:nothing_to_migrate)
      :checking --not owner--> :failed(:forbidden)

      :needs_migration --:begin--> :confirming_members   (members/invitations)
                       --:begin--> :setting_up           (nobody else)
      :confirming_members --{:confirm_members, true}--> :setting_up
                          (resume: :verifying); false stays put
      :setting_up --:vault_created--> :verifying   (effect {:redownload_vault})
      :verifying --{:vault_downloaded, {:ok, view}}, verify/2 == :ok--> :finalizing
                 --anything else--> :failed(:verification_mismatch)
      :finalizing --finalize ok--> :done
                  --:vault_changed--> :verifying (re-download, at most 3 rounds,
                       then :failed(:vault_changed))
                  --:changed--> :re_exporting --export--> :setting_up (rebuild)
                  --:busy | :rate_limited--> :finalizing (retry_after backoff,
                       at most 3 retries, then :failed(:busy))
                  --:members_present--> :failed(:members_present)

  Failures are `step: :failed` with `reason` (`:forbidden | :already_encrypted
  | :nothing_to_migrate | :too_large | :verification_mismatch | :busy |
  :changed | :vault_changed | :members_present | :no_vault | :export_failed | :vault_failed |
  :finalize_failed`). `terminal?/1` is true for `:done` and the reasons that
  retrying cannot fix (`:forbidden`, `:already_encrypted`,
  `:nothing_to_migrate`, `:too_large`, `:members_present`, `:no_vault`).
  From other failures `:retry` repeats the failed step (`:verification_mismatch`
  additionally accepts `:rebuild`, at most 2 times).

  ## Decisions

    * `:changed` (the digest moved on, e.g. a payment was logged): the
      plaintext is the source of truth until finalize, so re-export and
      REBUILD the vault from the new snapshot (CAS save over the existing
      vault, effect `{:rebuild_vault, snapshot}`), then re-download and verify
      again. At most 3 `:changed` rounds, then `:failed(:changed)`.
    * Page reload mid-flow: `:both` (vault exists, plaintext not finalized)
      re-exports and resumes at `:verifying`; if the vault no longer matches
      the fresh export the verification fails and `:rebuild` repairs it.
    * Members: nobody else is removed without `{:confirm_members, true}`;
      finalize only ever receives `confirm_remove_members` from that answer.

  ## Safety rule

  `:finalizing` is entered ONLY from `:verifying` by `{:vault_downloaded,
  {:ok, view}}` when `verify(export.snapshot, view) == :ok`. That transition
  sets `verified_digest` (the digest of the export verified against) and is
  the only place the `{:command, :migration_finalize, ...}` effect is created
  (the busy retry re-sends it from `:finalizing`, same digest). Leaving
  `:finalizing` clears `verified_digest`.

  ## verify/2 contract

  Compares the export snapshot with `VaultDoc.view(decoded re-downloaded doc)`
  for settings (excluding `updated_at`), `debts`, `payments`, `activity`,
  `retirement_profiles`: same ids, same record count (no extra or missing
  records, no duplicate ids) and every other field equal (cents, basis
  points, names, notes, actions, metadata, ids). Order-INSENSITIVE: records
  are matched by id, because `view/1` orders deterministically from stamps
  that the ledger may restamp, while each record carries its own `position`.
  Normalised away, and only these: `updated_at` and `inserted_at` on every
  record and in settings (the ledger/`from_snapshot` restamp them to the
  canonical stamp format), and atom-vs-string map keys. Anything else,
  including a decode error, is a mismatch.
  """

  @max_busy_retries 3
  @max_changed_rounds 3
  @max_vault_rounds 3
  @max_rebuilds 2
  @backoff_ms [1_000, 3_000, 9_000]
  @collections [:debts, :payments, :activity, :retirement_profiles]
  @terminal_reasons [
    :forbidden,
    :already_encrypted,
    :nothing_to_migrate,
    :too_large,
    :members_present,
    :no_vault
  ]

  def new do
    %{
      step: :checking,
      reason: nil,
      export: nil,
      confirmed: false,
      resume: false,
      verified_digest: nil,
      verified_vault: nil,
      vault_rounds: 0,
      busy_retries: 0,
      changed_rounds: 0,
      rebuilds: 0,
      rebuilding: false,
      retry_effect: nil
    }
  end

  @doc "The first effects (call once after `new/0`)."
  def start(state), do: {state, [{:command, :migration_status}]}

  def terminal?(%{step: :done}), do: true
  def terminal?(%{step: :failed, reason: reason}), do: reason in @terminal_reasons
  def terminal?(_state), do: false

  def members?(%{export: nil}), do: false

  def members?(%{export: export}),
    do: export.members != [] or export.pending_invitations > 0

  # --- apply ---------------------------------------------------------------------

  # status
  def apply(%{step: :checking} = s, {:status_result, %{ok: true, status: status} = reply}) do
    cond do
      Map.get(reply, :owner) != true ->
        {fail(s, :forbidden), []}

      status == :plaintext_only ->
        {s, [{:command, :migration_export}]}

      status == :both ->
        {%{s | resume: true}, [{:command, :migration_export}]}

      status in [:vault_only, :empty] ->
        {fail(s, :nothing_to_migrate), []}

      true ->
        {fail(s, :export_failed), []}
    end
  end

  def apply(%{step: :checking} = s, {:status_result, %{ok: false}}),
    do: {fail(s, :export_failed, {:command, :migration_status}), []}

  # export
  def apply(%{step: :checking} = s, {:export_result, %{ok: true} = r}) do
    s = %{s | export: export_of(r)}

    cond do
      s.resume and members?(s) -> {%{s | step: :confirming_members}, []}
      s.resume -> {%{s | step: :verifying}, [{:redownload_vault}]}
      true -> {%{s | step: :needs_migration}, []}
    end
  end

  def apply(%{step: :re_exporting} = s, {:export_result, %{ok: true} = r}) do
    s = %{s | export: export_of(r), step: :setting_up, rebuilding: true}
    {s, [{:rebuild_vault, s.export.snapshot}]}
  end

  def apply(%{step: step} = s, {:export_result, %{ok: false, error: error}})
      when step in [:checking, :re_exporting] do
    reason =
      if error in (@terminal_reasons ++ [:already_encrypted]), do: error, else: :export_failed

    {fail(s, reason, {:command, :migration_export}), []}
  end

  # begin / confirm
  def apply(%{step: :needs_migration} = s, :begin) do
    if members?(s) do
      {%{s | step: :confirming_members}, []}
    else
      {%{s | step: :setting_up}, [{:build_vault, s.export.snapshot}]}
    end
  end

  def apply(%{step: :confirming_members} = s, {:confirm_members, true}) do
    s = %{s | confirmed: true}

    if s.resume do
      {%{s | step: :verifying}, [{:redownload_vault}]}
    else
      {%{s | step: :setting_up}, [{:build_vault, s.export.snapshot}]}
    end
  end

  def apply(%{step: :confirming_members} = s, {:confirm_members, _other}), do: {s, []}

  # vault wizard
  def apply(%{step: :setting_up} = s, :vault_created),
    do: {%{s | step: :verifying, rebuilding: false}, [{:redownload_vault}]}

  # A failed REBUILD save (the vault already exists): `:retry` repeats the
  # rebuild save, it must not re-show the create wizard.
  def apply(
        %{step: :setting_up, rebuilding: true, export: %{snapshot: snapshot}} = s,
        :vault_failed
      ),
      do: {fail(s, :vault_failed, {:rebuild_vault, snapshot}), []}

  # Vault creation failed (network, server refusal): `:retry` rebuilds it from
  # the exported snapshot. Nothing is deleted at this point, so retrying is safe.
  def apply(%{step: :setting_up, export: %{snapshot: snapshot}} = s, :vault_failed),
    do: {fail(s, :vault_failed, {:build_vault, snapshot}), []}

  def apply(%{step: :setting_up} = s, :vault_failed),
    do: {fail(s, :vault_failed), []}

  # verify (the only way into :finalizing)
  # `vault_ref` is `%{rev: integer, sha256: hex}` of the EXACT blob that was
  # downloaded and verified; finalize is bound to it. A download event without
  # a well-formed ref can never finalize (fails closed, see the clause below).
  def apply(%{step: :verifying} = s, {:vault_downloaded, {:ok, view}, %{rev: rev, sha256: sha}})
      when is_integer(rev) and is_binary(sha) and sha != "" do
    case verify(s.export.snapshot, view) do
      :ok ->
        s = %{
          s
          | step: :finalizing,
            verified_digest: s.export.digest,
            verified_vault: %{rev: rev, sha256: sha},
            busy_retries: 0
        }

        {s, [finalize_effect(s)]}

      {:error, :verification_mismatch} ->
        {fail(s, :verification_mismatch, {:redownload_vault}), []}
    end
  end

  def apply(%{step: :verifying} = s, {:vault_downloaded, _error, _ref}),
    do: {fail(s, :verification_mismatch, {:redownload_vault}), []}

  def apply(%{step: :verifying} = s, {:vault_downloaded, _error}),
    do: {fail(s, :verification_mismatch, {:redownload_vault}), []}

  # finalize
  def apply(%{step: :finalizing} = s, {:finalize_result, %{ok: true}}),
    do: {%{s | step: :done, verified_digest: nil, verified_vault: nil, retry_effect: nil}, []}

  # The stored vault is no longer the one we verified (overwritten, rebuilt or
  # rolled back). Nothing was deleted: download and verify it again; a
  # mismatch is then repaired by a rebuild. Bounded.
  def apply(%{step: :finalizing} = s, {:finalize_result, %{ok: false, error: :vault_changed}}) do
    if s.vault_rounds >= @max_vault_rounds do
      {fail(s, :vault_changed, {:redownload_vault}), []}
    else
      s = %{
        s
        | step: :verifying,
          verified_digest: nil,
          verified_vault: nil,
          vault_rounds: s.vault_rounds + 1
      }

      {s, [{:redownload_vault}]}
    end
  end

  def apply(%{step: :finalizing} = s, {:finalize_result, %{ok: false, error: :changed}}) do
    if s.changed_rounds >= @max_changed_rounds do
      {fail(s, :changed), []}
    else
      s = %{
        s
        | step: :re_exporting,
          verified_digest: nil,
          verified_vault: nil,
          changed_rounds: s.changed_rounds + 1
      }

      {s, [{:command, :migration_export}]}
    end
  end

  def apply(%{step: :finalizing} = s, {:finalize_result, %{ok: false, error: error}})
      when error in [:busy, :rate_limited] do
    if s.busy_retries >= @max_busy_retries do
      {fail(s, :busy), []}
    else
      delay = Enum.at(@backoff_ms, s.busy_retries)
      {%{s | busy_retries: s.busy_retries + 1}, [{:retry_after, delay, finalize_effect(s)}]}
    end
  end

  def apply(%{step: :finalizing} = s, {:finalize_result, %{ok: false, error: error}})
      when error in [:forbidden, :members_present, :no_vault],
      do: {fail(s, error), []}

  def apply(%{step: :finalizing} = s, {:finalize_result, %{ok: false}}),
    do: {fail(s, :finalize_failed), []}

  # recovery from non-terminal failures
  def apply(%{step: :failed} = s, :retry) do
    if terminal?(s) or s.retry_effect == nil do
      {s, []}
    else
      retry(s)
    end
  end

  def apply(
        %{step: :failed, reason: :verification_mismatch, rebuilds: n} = s,
        :rebuild
      )
      when n < @max_rebuilds do
    {%{s | step: :setting_up, reason: nil, retry_effect: nil, rebuilds: n + 1, rebuilding: true},
     [{:rebuild_vault, s.export.snapshot}]}
  end

  def apply(state, _event), do: {state, []}

  defp retry(%{retry_effect: {:redownload_vault}} = s),
    do: {%{s | step: :verifying, reason: nil, retry_effect: nil}, [{:redownload_vault}]}

  defp retry(%{retry_effect: {:command, :migration_export}} = s),
    do: {%{s | step: :checking, reason: nil, retry_effect: nil}, [{:command, :migration_export}]}

  defp retry(%{retry_effect: {:command, :migration_status}} = s),
    do: {%{s | step: :checking, reason: nil, retry_effect: nil}, [{:command, :migration_status}]}

  defp retry(%{retry_effect: {:rebuild_vault, snapshot}} = s),
    do:
      {%{s | step: :setting_up, reason: nil, retry_effect: nil, rebuilding: true},
       [{:rebuild_vault, snapshot}]}

  defp retry(%{retry_effect: {:build_vault, snapshot}} = s),
    do: {%{s | step: :setting_up, reason: nil, retry_effect: nil}, [{:build_vault, snapshot}]}

  defp retry(s), do: {s, []}

  defp fail(s, reason, retry_effect \\ nil),
    do: %{
      s
      | step: :failed,
        reason: reason,
        verified_digest: nil,
        verified_vault: nil,
        retry_effect: retry_effect
    }

  defp finalize_effect(s),
    do:
      {:command, :migration_finalize,
       %{
         digest: s.verified_digest,
         confirm_remove_members: s.confirmed,
         vault_rev: s.verified_vault.rev,
         vault_blob_sha256: s.verified_vault.sha256
       }}

  defp export_of(r) do
    %{
      snapshot: r.snapshot,
      digest: r.digest,
      members: Map.get(r, :members) || [],
      pending_invitations: Map.get(r, :pending_invitations) || 0
    }
  end

  # --- verify --------------------------------------------------------------------

  @doc """
  `:ok` iff `view` (the `VaultDoc.view` of the re-downloaded, decrypted,
  decoded vault) holds exactly the export snapshot's data. See the moduledoc
  for the contract. Anything malformed is `{:error, :verification_mismatch}`.
  """
  def verify(export, view) when is_map(export) and is_map(view) do
    if settings_equal?(export, view) and
         Enum.all?(@collections, &collection_equal?(export, view, &1)) do
      :ok
    else
      {:error, :verification_mismatch}
    end
  end

  def verify(_export, _view), do: {:error, :verification_mismatch}

  defp settings_equal?(a, b) do
    case {Map.get(a, :settings), Map.get(b, :settings)} do
      {sa, sb} when is_map(sa) and is_map(sb) ->
        norm(Map.delete(sa, :updated_at)) == norm(Map.delete(sb, :updated_at))

      _ ->
        false
    end
  end

  defp collection_equal?(a, b, key) do
    with {:ok, ia} <- index(Map.get(a, key)),
         {:ok, ib} <- index(Map.get(b, key)) do
      ia == ib
    else
      _ -> false
    end
  end

  # id => normalised record; :error on a non-list, a non-map record, a record
  # without an id or a duplicate id.
  defp index(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, %{}}, fn
      %{id: id} = rec, {:ok, acc} when is_binary(id) ->
        if Map.has_key?(acc, id) do
          {:halt, :error}
        else
          {:cont, {:ok, Map.put(acc, id, norm(Map.drop(rec, [:updated_at, :inserted_at])))}}
        end

      _bad, _acc ->
        {:halt, :error}
    end)
  end

  defp index(_other), do: :error

  # Atom keys -> string keys, recursively (values untouched).
  defp norm(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {norm_key(k), norm(v)} end)

  defp norm(list) when is_list(list), do: Enum.map(list, &norm/1)
  defp norm(other), do: other

  defp norm_key(k) when is_atom(k), do: Atom.to_string(k)
  defp norm_key(k), do: k
end

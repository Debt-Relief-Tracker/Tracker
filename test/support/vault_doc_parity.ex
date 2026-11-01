defmodule DebtReliefTracker.VaultDocParity do
  @moduledoc """
  Test harness that drives the same change through `Storage.Plain` (against
  the test database) and `VaultDoc.Ledger` (starting from the same snapshot)
  and asserts `VaultDoc.view/1` equals Plain's snapshot afterwards, modulo
  ids and timestamps that cannot line up.

  What is compared exactly: everything except `updated_at`/`inserted_at`
  (both must be well-formed ISO timestamps), payment and activity `id`s
  (activity ids are fresh UUIDs on both sides; payment ids are DB-assigned on
  the Plain side), and `paid_off_at` (compared as set/unset). Debt, profile
  and (via `ctx.new_id`) every other id line up. List order is compared.
  """

  import ExUnit.Assertions

  alias DebtReliefTracker.Storage.Plain
  alias DebtReliefTracker.VaultDoc
  alias DebtReliefTracker.VaultDoc.{Ledger, Stamp}

  defstruct [:workspace, :user, :doc, :today, n: 0, log: []]

  def new(workspace, user \\ nil) do
    {:ok, snapshot} = Plain.load(workspace)

    %__MODULE__{
      workspace: workspace,
      user: user,
      doc: VaultDoc.from_snapshot(snapshot, now(0)),
      today: Date.to_iso8601(Date.utc_today())
    }
  end

  def now(n) do
    ~U[2026-11-01 12:00:00Z] |> DateTime.add(n, :second) |> DateTime.to_iso8601()
  end

  @doc """
  Applies `change` to both sides and compares. Options: `actor: :user | nil`
  (default `:user` when a user was given), `today:` overrides the Ledger's
  ctx date (it must equal today's date for the Plain side to agree).
  Returns `{parity, result}` where result is `{:ok, snapshot}` or the error.
  """
  def step(%__MODULE__{} = p, change, opts \\ []) do
    actor = if Keyword.get(opts, :actor, :user) == :user, do: p.user, else: nil
    {:ok, before} = Plain.load(p.workspace)
    plain = Plain.apply_change(p.workspace, actor, change)
    {:ok, after_} = Plain.load(p.workspace)

    new_ids =
      Enum.map(after_.debts -- before.debts, & &1.id) --
        Enum.map(before.debts, & &1.id)

    new_ids =
      ids_of(after_.debts, before.debts) ++
        ids_of(after_.payments, before.payments) ++
        ids_of(after_.retirement_profiles, before.retirement_profiles)

    _ = new_ids
    {:ok, queue} = Agent.start_link(fn -> new_ids end)

    ctx = %{
      now: now(p.n + 1),
      today: p.today,
      new_id: fn ->
        Agent.get_and_update(queue, fn
          [id | rest] -> {id, rest}
          [] -> {Ecto.UUID.generate(), []}
        end)
      end,
      actor: actor && actor.id,
      members: p.user && %{p.user.id => p.user.display_name}
    }

    ledger = Ledger.apply_change(p.doc, change, ctx)
    Agent.stop(queue)

    {doc, result} =
      case {plain, ledger} do
        {{:ok, snapshot}, {:ok, doc}} ->
          assert_same(snapshot, VaultDoc.view(doc), change)
          {doc, {:ok, snapshot}}

        {{:error, e}, {:error, e2}} ->
          assert e == e2, "error mismatch for #{inspect(change)}:\nplain:  #{inspect(e)}\nledger: #{inspect(e2)}"
          assert_same(after_, VaultDoc.view(p.doc), change)
          {p.doc, {:error, e}}

        other ->
          flunk("outcome mismatch for #{inspect(change)}:\n#{inspect(other, limit: 20)}")
      end

    {%{p | doc: doc, n: p.n + 1, log: [{change, result} | p.log]}, result}
  end

  defp ids_of(new, old) do
    old_ids = Enum.map(old, & &1.id)
    for %{id: id} <- new, id not in old_ids, do: id
  end

  def assert_same(plain_snapshot, view, change) do
    a = normalize(plain_snapshot)
    b = normalize(view)

    for key <- [:schema_version, :settings, :debts, :payments, :activity, :retirement_profiles] do
      assert Map.fetch!(a, key) == Map.fetch!(b, key),
             "#{key} differ after #{inspect(change)}\nplain:  #{inspect(Map.fetch!(a, key), pretty: true, limit: :infinity)}\nledger: #{inspect(Map.fetch!(b, key), pretty: true, limit: :infinity)}"
    end
  end

  def normalize(snapshot) do
    assert_iso(snapshot.settings.updated_at)

    %{
      snapshot
      | settings: Map.delete(snapshot.settings, :updated_at),
        debts:
          Enum.map(snapshot.debts, fn d ->
            assert_iso(d.updated_at)
            d |> Map.drop([:updated_at]) |> Map.update!(:paid_off_at, &(&1 && :set))
          end),
        payments:
          Enum.map(snapshot.payments, fn p ->
            assert_iso(p.inserted_at)
            assert_iso(p.updated_at)
            Map.drop(p, [:id, :inserted_at, :updated_at])
          end),
        activity:
          Enum.map(snapshot.activity, fn e ->
            assert_iso(e.inserted_at)
            e |> Map.drop([:id, :inserted_at]) |> Map.update!(:metadata, &round_amount/1)
          end),
        retirement_profiles:
          Enum.map(snapshot.retirement_profiles, fn r ->
            assert_iso(r.inserted_at)
            assert_iso(r.updated_at)
            Map.drop(r, [:inserted_at, :updated_at])
          end)
    }
  end

  defp assert_iso(value) do
    assert is_binary(value), "timestamp missing: #{inspect(value)}"
    assert {:ok, _} = Stamp.normalize(value), "not an ISO timestamp: #{inspect(value)}"
  end

  # Plain's reconcile payment amount keeps fractional cents; compare cents.
  defp round_amount(%{"amount" => amount} = metadata) do
    rounded = amount |> Decimal.new() |> Decimal.round(2, :half_up) |> Decimal.to_string(:normal)
    %{metadata | "amount" => rounded}
  end

  defp round_amount(metadata), do: metadata
end

defmodule DebtReliefTracker.E2EE.Vaults do
  @moduledoc """
  The blind, authenticated blob store behind E2EE mode
  (docs/architecture/0007-e2ee.md, roadmap Phase 10.6).

  The server holds opaque ciphertext (`blob`) and key wraps. It never parses,
  indexes, logs or decrypts either -- the only checks here are sizes, counts
  and the cheap shape of a wrap's fields. Every function is keyed by the
  `workspace` the caller derived server-side (`Holo.Context.workspace/1`);
  nothing here accepts a workspace id from client params, and every wrap query
  is scoped to that workspace, so another workspace's ids are simply "not
  found".

  Concurrency: `save/3` is a compare-and-swap on `rev`
  (`UPDATE ... WHERE workspace_id = ? AND rev = ?`), so of two writers holding
  the same base revision exactly one wins and the other gets the current
  server state to merge against.
  """

  import Ecto.Query

  alias DebtReliefTracker.Accounts.Workspace
  alias DebtReliefTracker.E2EE.{KeyWrap, Vault}
  alias DebtReliefTracker.Repo

  @max_blob_bytes 5 * 1024 * 1024
  @max_wraps 20
  # Never let Ecto's debug query log print bound parameters (the blob / wraps).
  @q [log: false]

  @type wrap_view :: KeyWrap.t()
  @type state :: %{rev: pos_integer(), blob: binary(), format_version: pos_integer()}

  def max_blob_bytes, do: @max_blob_bytes

  @doc "The workspace's vault with its key wraps (oldest first), or `:none`."
  def fetch(%Workspace{id: ws}) do
    case Repo.get(Vault, ws, @q) do
      nil ->
        :none

      vault ->
        {:ok,
         %{
           rev: vault.rev,
           blob: vault.blob,
           format_version: vault.format_version,
           key_wraps: list_wraps(ws)
         }}
    end
  end

  @doc "Whether the workspace has a vault (no blob read)."
  def exists?(%Workspace{id: ws}),
    do: Repo.exists?(from(v in Vault, where: v.workspace_id == ^ws), @q)

  @doc """
  Creates the workspace's vault and its first key wrap(s) in ONE transaction
  (all or nothing). `wraps` is one wrap map or a non-empty list of them (the
  setup wizard creates the chosen method's wrap and the recovery wrap
  together). `{:error, :exists}` if a vault is already there.
  """
  def create(%Workspace{id: ws}, blob, wraps) when is_binary(blob) do
    wraps = List.wrap(wraps)

    with :ok <- check_blob(blob),
         :ok <- check_wraps(wraps) do
      Repo.transaction(fn ->
        if Repo.exists?(from(v in Vault, where: v.workspace_id == ^ws), @q),
          do: Repo.rollback(:exists)

        %Vault{workspace_id: ws, rev: 1, format_version: 1, blob: blob}
        |> Repo.insert!(@q)

        Enum.each(wraps, fn attrs ->
          case insert_wrap(ws, attrs) do
            {:ok, _wrap} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

        %{rev: 1}
      end)
      |> unwrap_tx()
    end
  rescue
    # Two concurrent creates: the loser trips the primary key.
    Ecto.ConstraintError -> {:error, :exists}
  end

  @doc """
  Compare-and-swap: replaces the blob only if the server is still at
  `base_rev`, bumping `rev` by one. On a stale `base_rev` returns
  `{:conflict, %{rev, blob}}` -- the server's current state for the client to
  decrypt, merge and retry.
  """
  def save(%Workspace{id: ws}, base_rev, blob) when is_integer(base_rev) and is_binary(blob) do
    with :ok <- check_blob(blob) do
      now = DateTime.utc_now()

      query =
        from v in Vault,
          where: v.workspace_id == ^ws and v.rev == ^base_rev,
          update: [set: [blob: ^blob, updated_at: ^now], inc: [rev: 1]]

      Repo.transaction(fn ->
        case Repo.update_all(query, [], @q) do
          {1, _} ->
            {:ok, %{rev: base_rev + 1}}

          {0, _} ->
            case Repo.get(Vault, ws, @q) do
              nil -> {:error, :not_found}
              vault -> {:conflict, %{rev: vault.rev, blob: vault.blob}}
            end
        end
      end)
      |> case do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Adds an unlock method's wrap to an existing vault."
  def add_key_wrap(%Workspace{id: ws}, wrap_attrs) do
    with :ok <- check_wrap_sizes(wrap_attrs) do
      Repo.transaction(fn ->
        lock_vault(ws)

        cond do
          not Repo.exists?(from(v in Vault, where: v.workspace_id == ^ws), @q) ->
            Repo.rollback(:not_found)

          Repo.aggregate(from(w in KeyWrap, where: w.workspace_id == ^ws), :count, @q) >=
              @max_wraps ->
            Repo.rollback(:too_many_wraps)

          true ->
            case insert_wrap(ws, wrap_attrs) do
              {:ok, wrap} -> wrap
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      end)
      |> unwrap_tx()
    end
  rescue
    Ecto.ConstraintError -> {:error, {:invalid, %{id: ["has already been taken"]}}}
  end

  @doc """
  Removes one wrap. Refuses the last one (`{:error, :last_wrap}`: removing it
  would orphan the vault) and any id that is not this workspace's
  (`{:error, :not_found}`).
  """
  def remove_key_wrap(%Workspace{id: ws}, wrap_id) when is_binary(wrap_id) do
    with {:ok, wrap_id} <- Ecto.UUID.cast(wrap_id) do
      Repo.transaction(fn ->
        lock_vault(ws)

        scope = from w in KeyWrap, where: w.workspace_id == ^ws

        cond do
          not Repo.exists?(from(w in scope, where: w.id == ^wrap_id), @q) ->
            Repo.rollback(:not_found)

          Repo.aggregate(scope, :count, @q) <= 1 ->
            Repo.rollback(:last_wrap)

          true ->
            Repo.delete_all(from(w in scope, where: w.id == ^wrap_id), @q)
            :ok
        end
      end)
      |> unwrap_tx()
    else
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Changes one wrap's label (the only wrap field that is not cryptographically
  bound). `{:error, :not_found}` for any id that is not this workspace's.
  """
  def rename_key_wrap(%Workspace{id: ws}, wrap_id, label)
      when is_binary(wrap_id) and is_binary(label) do
    with {:ok, wrap_id} <- Ecto.UUID.cast(wrap_id),
         %KeyWrap{} = wrap <- Repo.get_by(KeyWrap, [id: wrap_id, workspace_id: ws], @q) do
      changeset =
        wrap
        |> Ecto.Changeset.cast(%{label: label}, [:label])
        |> Ecto.Changeset.validate_length(:label, max: KeyWrap.limits().label, count: :bytes)

      if changeset.valid?,
        do: changeset |> Repo.update(@q) |> rename_result(),
        else: {:error, {:invalid, errors(changeset)}}
    else
      _ -> {:error, :not_found}
    end
  end

  defp rename_result({:ok, %KeyWrap{} = wrap}), do: {:ok, wrap}
  defp rename_result({:error, cs}), do: {:error, {:invalid, errors(cs)}}

  @doc "Deletes the vault and all its wraps (account wipe)."
  def delete_vault(%Workspace{id: ws}) do
    Repo.transaction(fn ->
      Repo.delete_all(from(w in KeyWrap, where: w.workspace_id == ^ws), @q)

      case Repo.delete_all(from(v in Vault, where: v.workspace_id == ^ws), @q) do
        {1, _} -> :ok
        {0, _} -> Repo.rollback(:not_found)
      end
    end)
    |> unwrap_tx()
  end

  # --- internals ----------------------------------------------------------

  defp list_wraps(ws) do
    Repo.all(
      from w in KeyWrap, where: w.workspace_id == ^ws, order_by: [asc: w.inserted_at, asc: w.id]
    )
  end

  defp insert_wrap(ws, attrs) do
    attrs = normalize_attrs(attrs)

    changeset = KeyWrap.changeset(%KeyWrap{workspace_id: ws}, attrs)

    if changeset.valid?,
      do: insert(changeset),
      else: {:error, {:invalid, errors(changeset)}}
  end

  defp insert(changeset) do
    case Repo.insert(changeset, @q) do
      {:ok, wrap} -> {:ok, wrap}
      {:error, changeset} -> {:error, {:invalid, errors(changeset)}}
    end
  end

  # The id must be a UUID (it is also a primary key); other fields are cast.
  defp normalize_attrs(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    case Ecto.UUID.cast(Map.get(attrs, "id")) do
      {:ok, id} -> Map.put(attrs, "id", id)
      :error -> Map.delete(attrs, "id")
    end
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        placeholder = "%{#{key}}"

        if String.contains?(acc, placeholder) and is_integer(value),
          do: String.replace(acc, placeholder, Integer.to_string(value)),
          else: acc
      end)
    end)
  end

  # Serialises concurrent wrap changes on one vault (a row lock on Postgres;
  # SQLite already serialises writers) so the "last wrap" and wrap-count checks
  # cannot race.
  defp lock_vault(ws) do
    now = DateTime.utc_now()
    Repo.update_all(from(v in Vault, where: v.workspace_id == ^ws), [set: [updated_at: now]], @q)
  end

  defp check_blob(blob) when byte_size(blob) == 0, do: {:error, {:invalid, %{blob: ["is empty"]}}}
  defp check_blob(blob) when byte_size(blob) > @max_blob_bytes, do: {:error, :too_large}
  defp check_blob(_blob), do: :ok

  defp check_wraps([]), do: {:error, {:invalid, %{wrap: ["is invalid"]}}}

  defp check_wraps(wraps) when length(wraps) > @max_wraps, do: {:error, :too_many_wraps}

  defp check_wraps(wraps) do
    Enum.find_value(wraps, :ok, fn attrs ->
      case check_wrap_sizes(attrs) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp check_wrap_sizes(attrs) when is_map(attrs) do
    limits = KeyWrap.limits()

    too_large? =
      Enum.any?(attrs, fn {k, v} ->
        field =
          if is_atom(k), do: k, else: Enum.find(Map.keys(limits), &(Atom.to_string(&1) == k))

        max = field && Map.get(limits, field)
        max != nil and is_binary(v) and byte_size(v) > max
      end)

    if too_large?, do: {:error, :too_large}, else: :ok
  end

  defp check_wrap_sizes(_), do: {:error, {:invalid, %{wrap: ["is invalid"]}}}

  defp unwrap_tx({:ok, value}), do: {:ok, value} |> flatten()
  defp unwrap_tx({:error, reason}), do: {:error, reason}

  defp flatten({:ok, :ok}), do: :ok
  defp flatten(other), do: other
end

defmodule DebtReliefTrackerWeb.Holo.Components.VaultGate do
  @moduledoc """
  Server side of E2EE mode (docs/architecture/0007-e2ee.md, roadmap Phase 6):
  the Hologram commands that read and write the blind vault store
  (`DebtReliefTracker.E2EE.Vaults`). The UI is a stub -- it renders a hidden
  marker only; the setup/unlock flows are Phase 7.

  Rules every command here follows:

    * The workspace comes from `Holo.Context.workspace/1` (the session the
      `Holo.Auth` middleware resolved), NEVER from params.
    * The blob and wraps are opaque strings (the facade's base64url / `v1.<iv>.<ct>`
      envelopes). Nothing here parses, logs or inspects them.
    * Each command is rate limited per workspace (`E2EE.RateLimiter`).
    * Each command returns its outcome to the page through exactly ONE
      `put_action` (`:vault_result` on the page), as plain maps/strings.

  Client actions with the same names as the commands are provided so Phase 7
  UI can `put_action(name: :fetch_vault, target: "vault_gate")` and so on.
  """

  use Hologram.Component

  alias DebtReliefTracker.E2EE.{KeyWrap, RateLimiter, Vaults}
  alias DebtReliefTrackerWeb.Holo.Context

  middleware DebtReliefTrackerWeb.Holo.Auth

  def template do
    ~HOLO"""
    <div id="vault-gate" class="hidden" aria-hidden="true"></div>
    """
  end

  # --- client actions: thin wrappers that issue the commands ----------------

  def action(:fetch_vault, _params, component), do: put_command(component, :fetch_vault)

  def action(:create_vault, %{blob: blob, wrap: wrap}, component),
    do: put_command(component, :create_vault, blob: blob, wrap: wrap)

  def action(:save_vault, %{base_rev: base_rev, blob: blob}, component),
    do: put_command(component, :save_vault, base_rev: base_rev, blob: blob)

  def action(:add_key_wrap, %{wrap: wrap}, component),
    do: put_command(component, :add_key_wrap, wrap: wrap)

  def action(:remove_key_wrap, %{id: id}, component),
    do: put_command(component, :remove_key_wrap, id: id)

  def action(:delete_vault, _params, component), do: put_command(component, :delete_vault)

  # --- commands (server) ------------------------------------------------------

  def command(:fetch_vault, _params, server) do
    run(server, :fetch_vault, fn workspace ->
      case Vaults.fetch(workspace) do
        :none ->
          %{ok: true, exists: false}

        {:ok, vault} ->
          %{
            ok: true,
            exists: true,
            rev: vault.rev,
            blob: vault.blob,
            format_version: vault.format_version,
            key_wraps: Enum.map(vault.key_wraps, &wrap_map/1)
          }
      end
    end)
  end

  def command(:create_vault, %{blob: blob, wrap: wrap}, server)
      when is_binary(blob) and is_map(wrap) do
    run(server, :create_vault, fn workspace ->
      workspace |> Vaults.create(blob, wrap) |> reply()
    end)
  end

  def command(:save_vault, %{base_rev: base_rev, blob: blob}, server)
      when is_integer(base_rev) and is_binary(blob) do
    run(server, :save_vault, fn workspace ->
      case Vaults.save(workspace, base_rev, blob) do
        {:ok, %{rev: rev}} ->
          %{ok: true, rev: rev}

        {:conflict, %{rev: rev, blob: current}} ->
          %{ok: false, error: :conflict, rev: rev, blob: current}

        {:error, reason} ->
          %{ok: false, error: error_code(reason)}
      end
    end)
  end

  def command(:add_key_wrap, %{wrap: wrap}, server) when is_map(wrap) do
    run(server, :add_key_wrap, fn workspace ->
      case Vaults.add_key_wrap(workspace, wrap) do
        {:ok, %KeyWrap{} = added} -> %{ok: true, key_wrap: wrap_map(added)}
        {:error, reason} -> %{ok: false, error: error_code(reason)}
      end
    end)
  end

  def command(:remove_key_wrap, %{id: id}, server) when is_binary(id) do
    run(server, :remove_key_wrap, fn workspace ->
      workspace |> Vaults.remove_key_wrap(id) |> reply()
    end)
  end

  def command(:delete_vault, _params, server) do
    run(server, :delete_vault, fn workspace -> workspace |> Vaults.delete_vault() |> reply() end)
  end

  # Anything that did not match its clause above (wrong shape from a crafted
  # client): a plain error, never a crash that could echo params into logs.
  def command(op, _params, server) do
    put_action(server,
      name: :vault_result,
      target: "page",
      params: %{op: op, ok: false, error: :invalid}
    )
  end

  # --- internals ----------------------------------------------------------

  defp run(server, op, fun) do
    workspace = Context.workspace(server)

    result =
      case RateLimiter.check(workspace.id) do
        :ok -> fun.(workspace)
        {:error, :rate_limited} -> %{ok: false, error: :rate_limited}
      end

    put_action(server,
      name: :vault_result,
      target: "page",
      params: Map.put(result, :op, op)
    )
  end

  defp reply(:ok), do: %{ok: true}
  defp reply({:ok, %{rev: rev}}), do: %{ok: true, rev: rev}
  defp reply({:error, reason}), do: %{ok: false, error: error_code(reason)}

  defp error_code({:invalid, _errors}), do: :invalid
  defp error_code(reason) when is_atom(reason), do: reason

  defp wrap_map(%KeyWrap{} = wrap) do
    %{
      id: wrap.id,
      kind: wrap.kind,
      label: wrap.label,
      credential_id: wrap.credential_id,
      kdf_params: wrap.kdf_params,
      salt: wrap.salt,
      wrapped_key: wrap.wrapped_key
    }
  end
end

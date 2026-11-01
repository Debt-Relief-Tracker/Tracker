defmodule DebtReliefTracker.E2EEHelpers do
  @moduledoc false

  alias DebtReliefTracker.Accounts

  def oidc_user(sub) do
    Accounts.get_or_create_user_from_oidc!(%{
      "sub" => sub,
      "email" => "#{sub}@example.com",
      "name" => "User #{sub}"
    })
  end

  def workspace_of(user), do: Accounts.current_workspace_for_user(user)

  def enable_oidc do
    Application.put_env(:debt_relief_tracker, :oidc,
      issuer: "https://idp.example.com",
      client_id: "test-client",
      client_secret: "test-secret"
    )

    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:debt_relief_tracker, :oidc, nil) end)
  end

  def enable_e2ee do
    Application.put_env(:debt_relief_tracker, :e2ee, true)
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:debt_relief_tracker, :e2ee, false) end)
  end

  def b64u(n), do: String.duplicate("A", n)

  @doc "A well-shaped passphrase wrap (opaque fields; the server cannot verify them)."
  def passphrase_wrap(attrs \\ %{}) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        kind: "passphrase",
        label: "pass",
        kdf_params: ~s({"memoryKiB":65536,"iterations":3,"parallelism":1}),
        salt: b64u(22),
        wrapped_key: "v1." <> b64u(16) <> "." <> b64u(64)
      },
      attrs
    )
  end

  def passkey_wrap(attrs \\ %{}) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        kind: "passkey",
        label: "key",
        credential_id: "cred" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false),
        wrapped_key: "v1." <> b64u(16) <> "." <> b64u(64)
      },
      attrs
    )
  end
end

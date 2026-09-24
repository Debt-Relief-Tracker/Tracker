defmodule DebtReliefTracker.Accounts do
  @moduledoc """
  Users, workspaces, and workspace membership.

  See docs/architecture/0002-auth-and-sharing-model.md: a `Workspace` (not a
  `User`) is the unit debts/payments/settings belong to, so that sharing a
  workspace with another logged-in user (once OIDC is configured, Phase 7)
  doesn't require a data-model migration.
  """

  import Ecto.Query, warn: false

  require Logger

  alias DebtReliefTracker.Repo
  alias DebtReliefTracker.Settings

  alias DebtReliefTracker.Accounts.{
    User,
    Workspace,
    WorkspaceMember,
    WorkspaceInvitation,
    SentEmail,
    ApiToken,
    Scope,
    UserNotifier
  }

  @doc """
  Returns the single implicit user/workspace used in no-auth mode, creating
  it on first boot if it doesn't exist yet. Idempotent -- safe to call on
  every application start.
  """
  def ensure_default_workspace! do
    get_owned_workspace!(get_default_user!())
  end

  @doc """
  Returns the single implicit `User` used in no-auth mode (identified by a
  `nil` `external_subject`), creating it and its own workspace on first boot
  if it doesn't exist yet. Idempotent -- safe to call any time.
  """
  def get_default_user! do
    case Repo.one(from(u in User, where: is_nil(u.external_subject))) do
      nil ->
        {user, _workspace} =
          create_user_with_own_workspace!(
            %{display_name: "You", external_subject: nil},
            "My Debts"
          )

        user

      %User{} = user ->
        user
    end
  end

  @doc "Fetches a user by id."
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Marks whether `user` has seen the dashboard's onboarding tutorial. Used
  both to record completion/skip and to reset it via "View tutorial again."
  """
  def set_tutorial_seen(%User{} = user, seen?) do
    user
    |> User.tutorial_changeset(%{tutorial_seen: seen?})
    |> Repo.update()
  end

  @doc """
  Merges `attrs` (e.g. `%{"theme" => "dark"}`) into `user`'s
  `UserPreferences`, leaving other preferences as they are.
  """
  def update_preferences(%User{} = user, attrs) do
    user
    |> User.preferences_changeset(%{preferences: attrs})
    |> Repo.update()
  end

  @doc """
  The user whose preferences apply to `scope` -- its user, or in no-auth
  mode (ADR 0002) the implicit default user, same as the tutorial flag.
  """
  def preferences_user(%Scope{user: %User{} = user}), do: user
  def preferences_user(%Scope{user: nil}), do: get_default_user!()

  @doc """
  Finds or creates the `User` for an OIDC identity (matched on the
  provider's `sub` claim), creating their own workspace on first login
  (docs/architecture/0002-auth-and-sharing-model.md). Returns the user.

  `is_admin` is re-synced from the provider's role claim (see README's
  "Admin access" section) on every login, new or returning, so revoking the
  role in the IdP takes effect the next time that person logs in.
  `display_name` is re-synced from the `name` claim the same way, unless the
  user has set a local-only override (`display_name_editability/1`).
  """
  def get_or_create_user_from_oidc!(%{"sub" => subject} = claims) do
    admin? = admin_claim?(claims)

    user =
      case Repo.get_by(User, external_subject: subject) do
        %User{} = user ->
          changeset = User.oidc_sync_changeset(user, oidc_sync_attrs(user, claims, admin?))

          if changeset.changes == %{} do
            user
          else
            Repo.update!(changeset)
          end

        nil ->
          display_name = claims["name"] || claims["email"] || "New user"

          user_attrs = %{
            display_name: display_name,
            external_subject: subject,
            email: claims["email"]
          }

          {user, _workspace} =
            create_user_with_own_workspace!(user_attrs, "#{display_name}'s Debts", admin?)

          fulfill_pending_invitations(user)
          maybe_deliver_welcome_email(user)
          user
      end

    # Cheap (one indexed query, no-op if nothing matches) and run on every
    # login, not just the first -- also covers a manual retirement profile
    # added *after* this person already has an account.
    Settings.claim_retirement_profiles(user)
    user
  end

  defp oidc_sync_attrs(user, claims, admin?) do
    case claims["name"] do
      name when is_binary(name) and name != "" and not user.display_name_overridden ->
        %{is_admin: admin?, display_name: name}

      _ ->
        %{is_admin: admin?}
    end
  end

  @doc """
  How `user`'s display name can be edited from the app:

    * `:local` -- no-auth mode's implicit user; there's no IdP to sync with.
    * `:idp` -- an Auth0 database-connection user (`auth0|...` subject) with
      Management API write-back configured: saved to Auth0 first, then
      locally, and login sync keeps reading it back from the `name` claim.
    * `:read_only` -- an Auth0 social-connection user with write-back
      configured. Auth0 re-syncs `name` from Google etc. on every login, so an
      edit would silently revert; change it at that provider instead.
    * `:local_override` -- OIDC with no write-back path (a non-Auth0 IdP, or
      Auth0 without Management API credentials): saved locally and flagged
      so login sync stops overwriting it.
  """
  def display_name_editability(%User{external_subject: nil}), do: :local

  def display_name_editability(%User{external_subject: subject}) do
    cond do
      Application.get_env(:debt_relief_tracker, :auth0_management) == nil -> :local_override
      String.starts_with?(subject, "auth0|") -> :idp
      true -> :read_only
    end
  end

  @doc """
  Updates `user`'s display name per `display_name_editability/1`. For `:idp`
  users the IdP is written first and the local row only if that succeeds,
  so the two can't drift -- returns `{:error, :idp_update_failed}` otherwise.
  """
  def update_display_name(%User{} = user, attrs) do
    changeset = User.display_name_changeset(user, attrs)

    case {display_name_editability(user), changeset.valid?} do
      {:read_only, _} ->
        {:error, :read_only}

      {_, false} ->
        {:error, %{changeset | action: :update}}

      # The settings modal saves every section together, so this runs even
      # when only e.g. the currency changed -- don't call the IdP or flag
      # an override for a name that didn't change.
      {_, true} when changeset.changes == %{} ->
        {:ok, user}

      {:local, true} ->
        Repo.update(changeset)

      {:local_override, true} ->
        changeset
        |> Ecto.Changeset.put_change(:display_name_overridden, true)
        |> Repo.update()

      {:idp, true} ->
        name = Ecto.Changeset.get_field(changeset, :display_name)

        case DebtReliefTrackerWeb.Auth0Management.update_name(user.external_subject, name) do
          :ok ->
            Repo.update(changeset)

          {:error, reason} ->
            Logger.warning("Auth0 display name update failed: #{inspect(reason)}")
            {:error, :idp_update_failed}
        end
    end
  end

  # `OIDC_ROLES_CLAIM` (config/runtime.exs) -- default claims never carry
  # roles, so the IdP must be configured to add this custom claim to the ID
  # token (README's "Admin access" section has provider-specific steps).
  defp admin_claim?(claims) do
    claim = Application.get_env(:debt_relief_tracker, :oidc)[:roles_claim]
    "admin" in (claims[claim] || [])
  end

  defp maybe_deliver_welcome_email(user) do
    if Settings.get_site_settings().welcome_emails_enabled do
      UserNotifier.deliver_welcome_email(user)
    end
  end

  # Turns any pending invitations addressed to this email into real
  # WorkspaceMember access, now that the invitee has an account. Only
  # relevant on first login: share_workspace_with_email/3 only ever creates
  # an invitation when no matching User exists yet, so an existing user
  # never has invitations left to fulfill.
  defp fulfill_pending_invitations(%User{email: nil}), do: :ok

  defp fulfill_pending_invitations(%User{email: email} = user) do
    from(i in WorkspaceInvitation, where: i.email == ^email)
    |> Repo.all()
    |> Enum.each(fn invitation ->
      Repo.transaction(fn ->
        {:ok, _member} =
          %WorkspaceMember{}
          |> WorkspaceMember.changeset(%{
            workspace_id: invitation.workspace_id,
            user_id: user.id,
            role: :member
          })
          |> Repo.insert()

        {:ok, _} = Repo.delete(invitation)
      end)
    end)

    :ok
  end

  # Returns `{user, workspace}` -- both are needed by the two callers above,
  # which each only want one half.
  defp create_user_with_own_workspace!(user_attrs, workspace_name, is_admin \\ false) do
    Repo.transaction(fn ->
      {:ok, user} =
        %User{}
        |> User.changeset(user_attrs)
        |> User.admin_changeset(%{is_admin: is_admin})
        |> Repo.insert()

      {:ok, workspace} =
        %Workspace{}
        |> Workspace.changeset(%{name: workspace_name, owner_user_id: user.id})
        |> Repo.insert()

      {:ok, _member} =
        %WorkspaceMember{}
        |> WorkspaceMember.changeset(%{
          workspace_id: workspace.id,
          user_id: user.id,
          role: :owner
        })
        |> Repo.insert()

      {user, workspace}
    end)
    |> case do
      {:ok, {user, workspace}} -> {user, workspace}
    end
  end

  defp get_owned_workspace!(%User{id: user_id}) do
    Repo.get_by!(Workspace, owner_user_id: user_id)
  end

  @doc "Fetches a workspace by id."
  def get_workspace!(id), do: Repo.get!(Workspace, id)

  @doc """
  Every workspace in the system, regardless of owner -- used by
  `DuePayments.Scheduler` to sweep for due auto-log payments across every
  user's data, not just workspaces with an open LiveView connection.
  """
  def list_workspaces, do: Repo.all(Workspace)

  @doc "Lists the workspaces a user owns or is a member of."
  def list_workspaces_for_user(%User{id: user_id}) do
    from(w in Workspace,
      join: m in WorkspaceMember,
      on: m.workspace_id == w.id,
      where: m.user_id == ^user_id,
      order_by: w.name
    )
    |> Repo.all()
  end

  @doc """
  The workspace a user should currently see: `preferred_id` if they belong
  to it, otherwise their first workspace (owned or shared with them).
  """
  def current_workspace_for_user(%User{} = user, preferred_id \\ nil) do
    workspaces = list_workspaces_for_user(user)
    Enum.find(workspaces, List.first(workspaces), &(&1.id == preferred_id))
  end

  @doc "Whether a user owns a given workspace."
  def owner?(%Workspace{owner_user_id: owner_id}, %User{id: user_id}), do: owner_id == user_id

  @doc """
  Shares `workspace` with `email` (docs/architecture/0002-auth-and-sharing-model.md:
  an explicit grant, not attribution). If a `User` with that email has
  already logged in once, grants them member access immediately and emails
  them. If not, creates a pending `WorkspaceInvitation` and emails the
  address a sign-in link; it's fulfilled automatically the first time that
  email completes OIDC login (see `get_or_create_user_from_oidc!/1`).
  """
  def share_workspace_with_email(%Workspace{} = workspace, email, %User{} = inviter) do
    case Repo.get_by(User, email: email) do
      nil ->
        %WorkspaceInvitation{}
        |> WorkspaceInvitation.changeset(%{
          workspace_id: workspace.id,
          email: email,
          invited_by_user_id: inviter.id
        })
        |> Repo.insert()
        |> tap(fn
          {:ok, invitation} ->
            UserNotifier.deliver_workspace_invitation(invitation, workspace, inviter)

          {:error, _changeset} ->
            :ok
        end)

      %User{} = user ->
        %WorkspaceMember{}
        |> WorkspaceMember.changeset(%{
          workspace_id: workspace.id,
          user_id: user.id,
          role: :member
        })
        |> Repo.insert()
        |> tap(fn
          {:ok, _member} -> UserNotifier.deliver_workspace_shared(user, workspace, inviter)
          {:error, _changeset} -> :ok
        end)
    end
  end

  @doc "Pending invitations for a workspace, oldest first."
  def list_pending_invitations(%Workspace{id: workspace_id}) do
    from(i in WorkspaceInvitation,
      where: i.workspace_id == ^workspace_id,
      order_by: i.inserted_at
    )
    |> Repo.all()
  end

  @doc """
  Cancels a pending invitation belonging to `workspace`. `{:error, :not_found}`
  if it's already gone (accepted or previously canceled).
  """
  def cancel_invitation(%Workspace{id: workspace_id}, invitation_id) do
    case Repo.get_by(WorkspaceInvitation, id: invitation_id, workspace_id: workspace_id) do
      nil -> {:error, :not_found}
      invitation -> Repo.delete(invitation)
    end
  end

  @doc "Renames `workspace`. Caller is responsible for authorizing the rename."
  def update_workspace(%Workspace{} = workspace, attrs) do
    workspace
    |> Workspace.rename_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Accepted members of a workspace, excluding the owner's own membership row,
  oldest first, preloaded with :user.
  """
  def list_workspace_members(%Workspace{id: workspace_id}) do
    from(m in WorkspaceMember,
      where: m.workspace_id == ^workspace_id and m.role != :owner,
      order_by: m.inserted_at,
      preload: :user
    )
    |> Repo.all()
  end

  @doc """
  Every confirmed member of a workspace, owner included, preloaded with
  :user, owner first then oldest first. Unlike `list_workspace_members/1`
  (built for the "People" sharing list, which intentionally hides the
  owner's own row), callers that need the full roster of people who
  actually have access -- e.g. picking who to add a retirement profile for
  -- want this instead.
  """
  def list_confirmed_members(%Workspace{id: workspace_id}) do
    from(m in WorkspaceMember, where: m.workspace_id == ^workspace_id, preload: :user)
    |> Repo.all()
    |> Enum.sort_by(&{&1.role != :owner, &1.inserted_at})
  end

  @doc """
  Removes a member's access to `workspace`. `{:error, :not_found}` if already
  gone; `{:error, :cannot_remove_owner}` if `member_id` resolves to the
  workspace's own owner row.
  """
  def remove_member(%Workspace{} = workspace, member_id) do
    case Repo.get_by(WorkspaceMember, id: member_id, workspace_id: workspace.id) do
      nil ->
        {:error, :not_found}

      %WorkspaceMember{role: :owner} ->
        {:error, :cannot_remove_owner}

      %WorkspaceMember{} = member ->
        member = Repo.preload(member, :user)

        case Repo.delete(member) do
          {:ok, _} = result ->
            Settings.unlink_retirement_profile(workspace, member.user)
            result

          {:error, _} = error ->
            error
        end
    end
  end

  # `touch_last_seen/1` skips the write if the stored value is newer than
  # this, so a LiveView mount doesn't cost a DB write every time.
  @last_seen_throttle_seconds 5 * 60

  @doc """
  Stamps `last_login_at` (and `last_seen_at`) on a successful OIDC login --
  see AuthController's callback. Returns the updated user.
  """
  def record_login!(%User{} = user) do
    now = DateTime.utc_now()

    user
    |> Ecto.Changeset.change(last_login_at: now, last_seen_at: now)
    |> Repo.update!()
  end

  @doc """
  Bumps `last_seen_at` for the admin Users tab, called from UserAuth's
  on_mount on connected mounts. No-op (returns `user` unchanged) when the
  stored value is under 5 minutes old, and for `nil` (no-auth mode's
  userless scope). Uses `update_all` so `updated_at` isn't bumped by mere
  activity.
  """
  def touch_last_seen(nil), do: nil

  def touch_last_seen(%User{last_seen_at: last_seen_at} = user) do
    now = DateTime.utc_now()

    if last_seen_at && DateTime.diff(now, last_seen_at) < @last_seen_throttle_seconds do
      user
    else
      from(u in User, where: u.id == ^user.id) |> Repo.update_all(set: [last_seen_at: now])
      %{user | last_seen_at: now}
    end
  end

  @doc """
  One page of users for the admin Users tab, most recently seen first
  (never-seen last), preloaded with their workspace memberships. `:page` is
  clamped to `1..total_pages` so a stale `?page=` in the URL still lands on
  real rows. Returns `%{entries:, page:, per_page:, total:, total_pages:}`.
  """
  def list_users_for_admin(opts \\ []) do
    per_page = Keyword.get(opts, :per_page, 25)
    total = Repo.aggregate(User, :count)
    total_pages = max(ceil(total / per_page), 1)
    page = opts |> Keyword.get(:page, 1) |> max(1) |> min(total_pages)

    # `? IS NULL` rather than :desc_nulls_last -- portable across both
    # adapters (docs/architecture/0001-dual-database-adapter.md).
    entries =
      from(u in User,
        order_by: [
          asc: fragment("? IS NULL", u.last_seen_at),
          desc: u.last_seen_at,
          desc: u.inserted_at,
          asc: u.id
        ],
        limit: ^per_page,
        offset: ^((page - 1) * per_page),
        preload: [workspace_members: :workspace]
      )
      |> Repo.all()

    %{entries: entries, page: page, per_page: per_page, total: total, total_pages: total_pages}
  end

  @doc "A single user for the admin Users tab's detail modal, preloaded like `list_users_for_admin/1`."
  def get_user_for_admin!(id) do
    User |> Repo.get!(id) |> Repo.preload(workspace_members: :workspace)
  end

  @doc "Whether the current scope is an admin -- see UserAuth's :require_admin_scope on_mount."
  def admin?(%Scope{user: %User{is_admin: true}}), do: true
  def admin?(_scope), do: false

  @doc "Records that UserNotifier attempted to send an email, for the admin sent-email log."
  def record_sent_email!(attrs) do
    {:ok, sent_email} =
      %SentEmail{}
      |> SentEmail.changeset(attrs)
      |> Repo.insert()

    sent_email
  end

  @doc "Every sent email, newest first, for the admin sent-email log."
  def list_sent_emails(limit \\ 100) do
    from(e in SentEmail, order_by: [desc: e.inserted_at], limit: ^limit, preload: :user)
    |> Repo.all()
  end

  @doc "Fetches a sent-email log entry by id."
  def get_sent_email!(id), do: Repo.get!(SentEmail, id)

  @doc """
  Re-triggers a previously sent email from its stored `metadata`.
  `{:error, :gone}` when the record(s) needed to rebuild the email no longer
  exist (e.g. an invitation that's since been accepted or canceled).
  """
  def resend_email(%SentEmail{template: :welcome, user_id: user_id}) do
    case user_id && fetch(User, user_id) do
      nil -> {:error, :gone}
      user -> {:ok, UserNotifier.deliver_welcome_email(user)}
    end
  end

  def resend_email(%SentEmail{template: :workspace_shared, metadata: metadata}) do
    with %{"workspace_id" => workspace_id, "inviter_id" => inviter_id, "user_id" => user_id} <-
           metadata,
         %User{} = user <- fetch(User, user_id),
         %Workspace{} = workspace <- fetch(Workspace, workspace_id),
         %User{} = inviter <- fetch(User, inviter_id) do
      {:ok, UserNotifier.deliver_workspace_shared(user, workspace, inviter)}
    else
      _ -> {:error, :gone}
    end
  end

  def resend_email(%SentEmail{template: :workspace_invitation, metadata: metadata}) do
    with %{"invitation_id" => invitation_id} <- metadata,
         %WorkspaceInvitation{} = invitation <- fetch(WorkspaceInvitation, invitation_id),
         %Workspace{} = workspace <- fetch(Workspace, invitation.workspace_id),
         %User{} = inviter <- fetch(User, invitation.invited_by_user_id) do
      {:ok, UserNotifier.deliver_workspace_invitation(invitation, workspace, inviter)}
    else
      _ -> {:error, :gone}
    end
  end

  @doc "Every API token, newest first, for the admin API-tokens tab."
  def list_api_tokens do
    from(t in ApiToken, order_by: [desc: t.inserted_at])
    |> Repo.all()
  end

  @doc "Fetches an API token by id."
  def get_api_token!(id), do: Repo.get!(ApiToken, id)

  @doc """
  Creates an API token (docs/architecture/0006-support-api-and-tokens.md).
  `attrs` is admin-supplied (`name`, `scopes`); the raw token itself is
  generated here. `created_by` is the admin `User`, or `nil` in no-auth mode
  (ADR 0002). Returns `{:ok, raw_token, api_token}` on success -- the
  caller must show `raw_token` to the admin immediately, since it's never
  retrievable again -- or `{:error, changeset}`.
  """
  def create_api_token(attrs, created_by) do
    changeset = ApiToken.changeset(%ApiToken{}, attrs)

    if changeset.valid? do
      raw_token = generate_api_token()

      generated = %{
        token_hash: hash_api_token(raw_token),
        last_four: String.slice(raw_token, -4, 4),
        created_by_user_id: created_by && created_by.id
      }

      changeset
      |> ApiToken.put_generated(generated)
      |> Repo.insert()
      |> case do
        {:ok, api_token} -> {:ok, raw_token, api_token}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  @doc "Revokes an API token. Soft delete -- see `ApiToken.revoke_changeset/1`."
  def revoke_api_token(%ApiToken{} = api_token) do
    api_token
    |> ApiToken.revoke_changeset()
    |> Repo.update()
  end

  @doc """
  Authenticates a raw bearer token presented to the admin API, requiring it
  to carry `required_scope`. Returns `{:ok, api_token}`,
  `{:error, :invalid}` (unknown token), `{:error, :revoked}`, or
  `{:error, :insufficient_scope}`.
  """
  def authenticate_token(raw_token, required_scope) do
    case Repo.get_by(ApiToken, token_hash: hash_api_token(raw_token)) do
      nil ->
        {:error, :invalid}

      %ApiToken{} = api_token ->
        cond do
          ApiToken.revoked?(api_token) ->
            {:error, :revoked}

          not ApiToken.has_scope?(api_token, required_scope) ->
            {:error, :insufficient_scope}

          true ->
            {:ok, api_token} = Repo.update(ApiToken.touch_changeset(api_token))
            {:ok, api_token}
        end
    end
  end

  defp generate_api_token do
    "drt_" <> (32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  defp hash_api_token(raw_token) do
    :sha256 |> :crypto.hash(raw_token) |> Base.encode16(case: :lower)
  end

  # `Repo.get/2` raises `Ecto.Query.CastError` (rather than returning `nil`)
  # when the id can't be cast to the schema's primary key type -- which a
  # stale integer id embedded in `sent_emails.metadata` (from before ids
  # were converted to UUIDs) would trigger. Guarding with `Ecto.UUID.cast/1`
  # first lets a bad id flow into the existing `{:error, :gone}` path above
  # instead of crashing the admin LiveView.
  defp fetch(schema, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(schema, uuid)
      :error -> nil
    end
  end
end

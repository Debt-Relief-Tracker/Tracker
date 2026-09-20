defmodule DebtReliefTracker.Settings.RetirementProfile do
  @moduledoc """
  One household member's income/retirement inputs, scoped to a `Workspace`.

  `user_id` set means it's linked to a confirmed workspace member (the owner
  or a `WorkspaceMember`) -- only confirmed members can have a profile.
  `user_id` nil means it's a manual/offline person with no account, whose
  display name is the typed-in `name`. A manual profile's optional
  `claim_email` lets it auto-link to a real account later, the moment that
  email also becomes a confirmed member of the same workspace -- see
  `Settings.claim_retirement_profiles/1` -- mirroring how a
  `WorkspaceInvitation` turns into a `WorkspaceMember` once its invitee logs
  in.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias DebtReliefTracker.Accounts.{User, Workspace}
  alias DebtReliefTracker.Encrypted

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "retirement_profiles" do
    field :name, Encrypted.Binary, source: :name_enc
    # claim_email stays plaintext -- see docs/architecture/0005-field-level-encryption.md:
    # it carries a partial unique DB index and a plaintext WHERE-equality
    # lookup (Settings.claim_retirement_profiles/1), both of which a
    # random-IV cipher would silently break, and the same email is already
    # plaintext in users.email/workspace_invitations.email, so encrypting
    # only this copy wouldn't meaningfully protect anything.
    field :claim_email, :string
    field :current_age, Encrypted.Integer, source: :current_age_enc
    field :retirement_age, Encrypted.Integer, source: :retirement_age_enc
    # No schema-level `default:` on the numeric fields below: Ecto validates
    # a field's default at compile time by calling the type's `dump/1`,
    # which for an encrypted type needs the Vault running -- unavailable
    # during a plain `mix compile`. Not a behavior change: every changeset
    # that creates a RetirementProfile (`member_changeset/4`,
    # `manual_changeset/3`) already requires all of `@numeric_fields` via
    # `validate_required/2`, so a struct-level default was never the value
    # actually persisted.
    field :current_retirement_savings, Encrypted.Decimal, source: :current_retirement_savings_enc

    field :monthly_retirement_contribution, Encrypted.Decimal,
      source: :monthly_retirement_contribution_enc

    field :monthly_gross_income, Encrypted.Decimal, source: :monthly_gross_income_enc

    field :post_debt_investment_pct, Encrypted.Decimal, source: :post_debt_investment_pct_enc

    field :expected_annual_return_pct, Encrypted.Decimal, source: :expected_annual_return_pct_enc

    belongs_to :workspace, Workspace
    belongs_to :user, User

    timestamps()
  end

  @numeric_fields [
    :current_age,
    :retirement_age,
    :current_retirement_savings,
    :monthly_retirement_contribution,
    :monthly_gross_income,
    :post_debt_investment_pct,
    :expected_annual_return_pct
  ]

  @doc "The name to show for this profile: the linked user's display name, or the manually-typed name."
  def display_name(%__MODULE__{user_id: nil, name: name}), do: name
  def display_name(%__MODULE__{user: %User{display_name: display_name}}), do: display_name

  @doc "Creates a profile linked to a confirmed workspace member (owner or `WorkspaceMember`)."
  def member_changeset(profile, %Workspace{id: workspace_id}, %User{id: user_id}, attrs) do
    profile
    |> cast(attrs, @numeric_fields)
    |> put_change(:workspace_id, workspace_id)
    |> put_change(:user_id, user_id)
    |> put_change(:name, nil)
    |> put_change(:claim_email, nil)
    |> validate_required([:workspace_id, :user_id] ++ @numeric_fields)
    |> validate_profile_fields()
    |> unique_constraint([:workspace_id, :user_id], error_key: :user_id)
  end

  @doc "Creates a profile for someone with no account -- a typed name, and an optional email to auto-link later."
  def manual_changeset(profile, %Workspace{id: workspace_id}, attrs) do
    profile
    |> cast(attrs, [:name, :claim_email] ++ @numeric_fields)
    |> put_change(:workspace_id, workspace_id)
    |> validate_required([:workspace_id, :name] ++ @numeric_fields)
    |> validate_profile_fields()
    |> unique_constraint([:workspace_id, :claim_email], error_key: :claim_email)
  end

  @doc "Edits an existing profile's numbers, and (for manual profiles only) its name/email."
  def update_changeset(%__MODULE__{user_id: nil} = profile, attrs) do
    profile
    |> cast(attrs, [:name, :claim_email] ++ @numeric_fields)
    |> validate_required([:name] ++ @numeric_fields)
    |> validate_profile_fields()
    |> unique_constraint([:workspace_id, :claim_email], error_key: :claim_email)
  end

  def update_changeset(%__MODULE__{} = profile, attrs) do
    profile
    |> cast(attrs, @numeric_fields)
    |> validate_required(@numeric_fields)
    |> validate_profile_fields()
  end

  @doc "Converts a manual profile into one linked to `user`, once their email joins the workspace."
  def claim_changeset(profile, %User{id: user_id}) do
    profile
    |> change(user_id: user_id, name: nil, claim_email: nil)
    |> unique_constraint([:workspace_id, :user_id], error_key: :user_id)
  end

  @doc "Downgrades a linked profile back to a manual one -- e.g. when the linked user's membership is removed."
  def unlink_changeset(profile, %User{display_name: display_name, email: email}) do
    profile
    |> change(user_id: nil, name: display_name, claim_email: email)
    |> validate_required([:name])
    |> unique_constraint([:workspace_id, :claim_email], error_key: :claim_email)
  end

  defp validate_profile_fields(changeset) do
    changeset
    |> validate_number(:current_age, greater_than_or_equal_to: 0, less_than_or_equal_to: 120)
    |> validate_number(:retirement_age, greater_than_or_equal_to: 1, less_than_or_equal_to: 120)
    |> validate_number(:current_retirement_savings, greater_than_or_equal_to: 0)
    |> validate_number(:monthly_retirement_contribution, greater_than_or_equal_to: 0)
    |> validate_number(:monthly_gross_income, greater_than_or_equal_to: 0)
    |> validate_number(:post_debt_investment_pct,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_number(:expected_annual_return_pct,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 30
    )
    |> validate_retirement_age_after_current_age()
  end

  defp validate_retirement_age_after_current_age(changeset) do
    current_age = get_field(changeset, :current_age)
    retirement_age = get_field(changeset, :retirement_age)

    if is_integer(current_age) and is_integer(retirement_age) and retirement_age <= current_age do
      add_error(changeset, :retirement_age, "must be greater than current age")
    else
      changeset
    end
  end
end

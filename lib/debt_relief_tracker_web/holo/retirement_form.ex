defmodule DebtReliefTrackerWeb.Holo.RetirementForm do
  @moduledoc """
  Pure, client-safe form logic for the retirement profile form
  (`Holo.Components.RetirementModal`): text <-> cents / basis points with
  integer string math, and validation that mirrors
  `Settings.RetirementProfile`'s changeset so the user gets the same messages
  without a round trip. (`Storage.Plain` still validates on the server.)

  A form is a map of strings keyed by field atom (`blank/1`); `build_change/3`
  turns it into a `Storage` change tuple or a `%{field => [message]}` map.
  """

  @numeric [
    {:current_age, "Current age", :int},
    {:retirement_age, "Target retirement age", :int},
    {:current_retirement_savings, "Current retirement savings", :cents},
    {:monthly_retirement_contribution, "Current monthly retirement contribution", :cents},
    {:monthly_gross_income, "Monthly gross income", :cents},
    {:post_debt_investment_bp, "% of income to invest once debt-free", :percent},
    {:expected_annual_return_bp, "Expected annual return (%)", :percent}
  ]

  # {min, max} per field, in storage units (years / cents / basis points).
  @ranges %{
    current_age: {0, 120},
    retirement_age: {1, 120},
    current_retirement_savings: {0, nil},
    monthly_retirement_contribution: {0, nil},
    monthly_gross_income: {0, nil},
    post_debt_investment_bp: {0, 10_000},
    expected_annual_return_bp: {0, 3_000}
  }

  @doc "The numeric inputs, in display order: `{field, label, kind}`."
  def numeric_fields, do: @numeric

  @doc "An empty form, with `user_id` preselected for the member picker."
  def blank(user_id \\ "") do
    %{
      user_id: user_id,
      name: "",
      claim_email: "",
      current_age: "",
      retirement_age: "",
      current_retirement_savings: "",
      monthly_retirement_contribution: "",
      monthly_gross_income: "",
      post_debt_investment_bp: "",
      expected_annual_return_bp: ""
    }
  end

  @doc "A form pre-filled from a snapshot retirement profile (for editing)."
  def from_profile(profile) do
    %{
      user_id: profile.user_id || "",
      name: profile.name || "",
      claim_email: profile.claim_email || "",
      current_age: Integer.to_string(profile.current_age),
      retirement_age: Integer.to_string(profile.retirement_age),
      current_retirement_savings: cents_to_text(profile.current_retirement_savings),
      monthly_retirement_contribution: cents_to_text(profile.monthly_retirement_contribution),
      monthly_gross_income: cents_to_text(profile.monthly_gross_income),
      post_debt_investment_bp: bp_to_text(profile.post_debt_investment_bp),
      expected_annual_return_bp: bp_to_text(profile.expected_annual_return_bp)
    }
  end

  @doc "150050 -> \"1500.50\"."
  def cents_to_text(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    abs_cents = abs(cents)
    frac = rem(abs_cents, 100)
    pad = if frac < 10, do: "0", else: ""
    "#{sign}#{div(abs_cents, 100)}.#{pad}#{frac}"
  end

  @doc "Basis points of a percent: 750 -> \"7.5\", 1500 -> \"15\", 725 -> \"7.25\"."
  def bp_to_text(bp) when is_integer(bp) do
    whole = div(bp, 100)
    frac = rem(bp, 100)

    cond do
      frac == 0 -> Integer.to_string(whole)
      rem(frac, 10) == 0 -> "#{whole}.#{div(frac, 10)}"
      frac < 10 -> "#{whole}.0#{frac}"
      true -> "#{whole}.#{frac}"
    end
  end

  @doc """
  Parses decimal text into an integer scaled by `10^scale`, rounding half up:
  `parse_scaled("12.345", 2)` -> `{:ok, 1235}`. Returns `:blank` for empty
  text and `:error` for anything that is not a plain (optionally negative)
  decimal number.
  """
  def parse_scaled(text, scale) do
    case String.trim(text) do
      "" -> :blank
      "-" <> rest -> negate(unsigned(rest, scale))
      rest -> unsigned(rest, scale)
    end
  end

  defp negate({:ok, n}), do: {:ok, -n}
  defp negate(other), do: other

  defp unsigned(text, scale) do
    case String.split(text, ".") do
      [whole] -> scaled(whole, "", scale)
      [whole, frac] -> scaled(whole, frac, scale)
      _ -> :error
    end
  end

  defp scaled(whole, frac, scale) do
    digits = whole <> frac

    if digits != "" and all_digits?(digits) do
      padded = String.pad_trailing(frac, scale + 1, "0")
      kept = String.slice(padded, 0, scale)
      next = String.slice(padded, scale, 1)
      base = String.to_integer("0" <> whole <> kept)
      {:ok, if(next >= "5", do: base + 1, else: base)}
    else
      :error
    end
  end

  defp all_digits?(text), do: text |> String.graphemes() |> Enum.all?(&digit?/1)

  defp digit?(grapheme), do: grapheme >= "0" and grapheme <= "9" and String.length(grapheme) == 1

  @doc """
  Validates `form` and builds the `Storage` change.

  `mode` is `{:add, "member" | "manual"}` or `{:update, profile_id, manual?}`.
  Returns `{:ok, change}` or `{:error, %{field => [message]}}`.
  """
  def build_change(mode, form) do
    {attrs, errors} = numeric_attrs(form)
    errors = add_ages_order_error(attrs, errors)
    {extra, errors} = identity_attrs(mode, form, errors)

    if errors == %{} do
      {:ok, change(mode, form, Map.merge(attrs, extra))}
    else
      {:error, errors}
    end
  end

  defp change({:add, "member"}, form, attrs),
    do: {:add_member_retirement_profile, form.user_id, attrs}

  defp change({:add, "manual"}, _form, attrs), do: {:add_manual_retirement_profile, attrs}
  defp change({:update, id, _manual?}, _form, attrs), do: {:update_retirement_profile, id, attrs}

  # Name / claim email apply to manual profiles only; a member needs a pick.
  defp identity_attrs({:add, "member"}, form, errors) do
    if form.user_id == "",
      do: {%{}, Map.put(errors, :user_id, ["can't be blank"])},
      else: {%{}, errors}
  end

  defp identity_attrs({:add, "manual"}, form, errors), do: manual_identity(form, errors)
  defp identity_attrs({:update, _id, true}, form, errors), do: manual_identity(form, errors)
  defp identity_attrs({:update, _id, false}, _form, errors), do: {%{}, errors}

  defp manual_identity(form, errors) do
    name = String.trim(form.name)
    email = String.trim(form.claim_email)
    errors = if name == "", do: Map.put(errors, :name, ["can't be blank"]), else: errors
    {%{name: name, claim_email: if(email == "", do: nil, else: email)}, errors}
  end

  defp numeric_attrs(form) do
    Enum.reduce(@numeric, {%{}, %{}}, fn {field, _label, kind}, {attrs, errors} ->
      case parse_field(kind, Map.get(form, field, "")) do
        :blank ->
          {attrs, Map.put(errors, field, ["can't be blank"])}

        :error ->
          {attrs, Map.put(errors, field, ["is invalid"])}

        {:ok, value} ->
          case range_error(field, value) do
            nil -> {Map.put(attrs, field, value), errors}
            message -> {attrs, Map.put(errors, field, [message])}
          end
      end
    end)
  end

  defp parse_field(:int, text) do
    case parse_scaled(text, 0) do
      {:ok, n} -> if String.contains?(text, "."), do: :error, else: {:ok, n}
      other -> other
    end
  end

  defp parse_field(_money_or_percent, text), do: parse_scaled(text, 2)

  defp range_error(field, value) do
    {min, max} = Map.fetch!(@ranges, field)

    cond do
      value < min -> "must be greater than or equal to #{display_bound(field, min)}"
      max != nil and value > max -> "must be less than or equal to #{display_bound(field, max)}"
      true -> nil
    end
  end

  # Bounds are stored in cents / basis points; messages quote them in the
  # units the user typed (cents -> dollars never arises: money minimum is 0).
  defp display_bound(field, bound) when field in [:post_debt_investment_bp, :expected_annual_return_bp],
    do: Integer.to_string(div(bound, 100))

  defp display_bound(_field, bound), do: Integer.to_string(bound)

  defp add_ages_order_error(attrs, errors) do
    current = Map.get(attrs, :current_age)
    retirement = Map.get(attrs, :retirement_age)

    if current != nil and retirement != nil and retirement <= current and
         not Map.has_key?(errors, :retirement_age) do
      Map.put(errors, :retirement_age, ["must be greater than current age"])
    else
      errors
    end
  end

  @doc "Turns a `Storage` error into the form's `%{field => [message]}` map."
  def errors_from({:invalid, errors}), do: errors
  def errors_from(:not_found), do: %{base: ["could not be found -- reload and try again"]}
  def errors_from(_other), do: %{base: ["could not be saved"]}
end

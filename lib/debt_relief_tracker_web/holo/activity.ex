defmodule DebtReliefTrackerWeb.Holo.Activity do
  @moduledoc """
  Display helpers for the activity log, rendered from `snapshot.activity`
  entries (`%{id, action, debt_id, user_id, metadata, inserted_at}`, enums and
  timestamps as strings, `metadata` amounts as decimal strings). Client-safe:
  no Decimal / DateTime / regex -- money goes through `Holo.Format` as integer
  cents. Mirrors the wording of `DashboardLive.activity_description/2`.
  """

  alias DebtReliefTrackerWeb.Holo.Format

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  @digits ~w(0 1 2 3 4 5 6 7 8 9)

  @doc """
  One-line description. `debts` is `snapshot.debts`, `actors` a map of
  user id -> display name (server-supplied; missing ids read as "Someone").
  """
  def description(entry, debts, actors, currency) do
    case entry.action do
      "debt_added" ->
        "#{actor(entry, actors)} added #{debt_name(entry, debts)}"

      "debt_updated" ->
        "#{actor(entry, actors)} updated #{debt_name(entry, debts)}"

      "debt_paid_off" ->
        "#{actor(entry, actors)} marked #{debt_name(entry, debts)} as paid off"

      "debt_deleted" ->
        "#{actor(entry, actors)} deleted #{debt_name(entry, debts)}"

      "payment_logged" ->
        "#{actor(entry, actors)} logged a #{amount(entry, currency)} payment on #{debt_name(entry, debts)}"

      "payment_auto_logged" ->
        "Auto-logged a #{amount(entry, currency)} payment on #{debt_name(entry, debts)}"

      "due_payment_skipped" ->
        "#{actor(entry, actors)} skipped this month's payment on #{debt_name(entry, debts)}"

      other ->
        other
    end
  end

  def actor(entry, actors) do
    case Map.get(actors, entry.user_id) do
      name when is_binary(name) -> name
      _ -> "Someone"
    end
  end

  @doc "The live debt's name, else the name recorded in the entry (deleted debts), else \"a debt\"."
  def debt_name(entry, debts) do
    live = Enum.find(debts, fn debt -> debt.id == entry.debt_id end)
    recorded = Map.get(entry.metadata || %{}, "name")

    cond do
      live != nil -> live.name
      is_binary(recorded) -> recorded
      true -> "a debt"
    end
  end

  defp amount(entry, currency) do
    case amount_cents(Map.get(entry.metadata || %{}, "amount")) do
      nil -> "an unknown amount"
      cents -> Format.money(cents, currency)
    end
  end

  @doc """
  "50.00" -> 5000, "12.345" -> 1235 (rounded half up), `nil`/garbage -> `nil`.
  Integer string math only.
  """
  def amount_cents(str) when is_binary(str) do
    {sign, rest} =
      case str do
        "-" <> r -> {-1, r}
        _ -> {1, str}
      end

    case String.split(rest, ".") do
      [whole] ->
        if digits?(whole), do: sign * String.to_integer(whole) * 100

      [whole, frac] ->
        if digits?(whole) and (frac == "" or digits?(frac)) do
          padded = frac <> "000"
          cents = String.to_integer(String.slice(padded, 0, 2))
          up = if String.to_integer(String.slice(padded, 2, 1)) >= 5, do: 1, else: 0
          sign * (String.to_integer(whole) * 100 + cents + up)
        end

      _ ->
        nil
    end
  end

  def amount_cents(_), do: nil

  defp digits?(s), do: s != "" and Enum.all?(String.graphemes(s), fn g -> g in @digits end)

  @doc ~S|"2026-07-11T14:03:00.1Z" -> "Jul 11, 2026 02:03 PM" (UTC, like the LiveView).|
  def format_when(iso) when is_binary(iso) do
    year = String.slice(iso, 0, 4)
    month = String.to_integer(String.slice(iso, 5, 2))
    day = String.slice(iso, 8, 2)
    hour = String.to_integer(String.slice(iso, 11, 2))
    minute = String.slice(iso, 14, 2)
    suffix = if hour >= 12, do: "PM", else: "AM"
    hour12 = rem(hour + 11, 12) + 1
    hour_str = if hour12 < 10, do: "0#{hour12}", else: Integer.to_string(hour12)

    "#{Enum.at(@months, month - 1)} #{day}, #{year} #{hour_str}:#{minute} #{suffix}"
  end

  def format_when(_), do: ""
end

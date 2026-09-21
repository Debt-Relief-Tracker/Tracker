defmodule DebtReliefTracker.Types.StringList do
  @moduledoc """
  Stores a list of strings as a JSON-encoded text column, e.g.
  `ApiToken.scopes`. Not `{:array, :string}` -- ADR 0001 (dual database
  adapter) requires migrations to avoid Postgres-only types so the same
  migration file works on SQLite too; a JSON-encoded string column works
  identically on both.
  """

  use Ecto.Type

  def type, do: :string

  def cast(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1) do
      {:ok, value}
    else
      :error
    end
  end

  def cast(_), do: :error

  def load(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> :error
    end
  end

  def dump(value) when is_list(value), do: Jason.encode(value)
  def dump(_), do: :error
end

defmodule DebtReliefTracker.VaultTest do
  use DebtReliefTracker.DataCase

  alias DebtReliefTracker.Encrypted
  alias DebtReliefTracker.{Accounts, Debts}

  describe "Encrypted.Binary" do
    test "round-trips strings, including unicode/emoji/quotes" do
      for value <- ["", "hello", "Chase Sapphire", "café ☕", ~s(quote " and ' marks)] do
        assert {:ok, ^value} = roundtrip(Encrypted.Binary, value)
      end
    end

    test "round-trips nil" do
      assert {:ok, nil} = roundtrip(Encrypted.Binary, nil)
    end
  end

  describe "Encrypted.Integer" do
    test "round-trips integers, including negatives and zero" do
      for value <- [-5, 0, 1, 120] do
        assert {:ok, ^value} = roundtrip(Encrypted.Integer, value)
      end
    end

    test "round-trips nil" do
      assert {:ok, nil} = roundtrip(Encrypted.Integer, nil)
    end
  end

  describe "Encrypted.Decimal" do
    test "round-trips decimals exactly, including negatives, zero, and high precision" do
      for value <- ["0", "0.00", "-1", "99999999.99", "0.000001", "2677.03", "15.0", "7.0"] do
        decimal = Decimal.new(value)
        assert {:ok, result} = roundtrip(Encrypted.Decimal, decimal)
        assert Decimal.equal?(result, decimal)
      end
    end

    test "casts and round-trips a raw float (schema default style)" do
      assert {:ok, result} = roundtrip(Encrypted.Decimal, 15.0)
      assert Decimal.equal?(result, Decimal.new("15.0"))
    end

    test "casts and round-trips a raw integer (schema default style)" do
      assert {:ok, result} = roundtrip(Encrypted.Decimal, 0)
      assert Decimal.equal?(result, Decimal.new("0"))
    end

    test "round-trips nil" do
      assert {:ok, nil} = roundtrip(Encrypted.Decimal, nil)
    end
  end

  describe "Encrypted.Map" do
    test "round-trips a nested map, with atom keys coming back as strings" do
      value = %{"name" => "Chase Sapphire", "nested" => %{"a" => 1, "b" => [1, 2, 3]}}
      assert {:ok, ^value} = roundtrip(Encrypted.Map, value)
    end

    test "round-trips an empty map" do
      assert {:ok, %{}} = roundtrip(Encrypted.Map, %{})
    end

    test "round-trips nil" do
      assert {:ok, nil} = roundtrip(Encrypted.Map, nil)
    end
  end

  test "two encryptions of the same value produce different ciphertext (random IV)" do
    {:ok, a} = Encrypted.Binary.dump("same value")
    {:ok, b} = Encrypted.Binary.dump("same value")
    refute a == b
  end

  describe "stored ciphertext" do
    test "does not contain the plaintext debt name or balance" do
      workspace = Accounts.ensure_default_workspace!()

      {:ok, debt} =
        Debts.create_debt(workspace, nil, %{
          "name" => "Chase Sapphire Reserve",
          "type" => "revolving",
          "balance" => "12345.67",
          "apr" => "20.00",
          "minimum_payment_rate" => "0.02"
        })

      %{rows: [[name_enc, balance_enc]]} =
        Ecto.Adapters.SQL.query!(
          Repo.active_repo(),
          "SELECT name_enc, balance_enc FROM debts WHERE id = ?",
          [debt.id]
        )

      refute name_enc =~ "Chase Sapphire Reserve"
      refute balance_enc =~ "12345.67"
    end
  end

  defp roundtrip(type, value) do
    with {:ok, cast} <- type.cast(value),
         {:ok, dumped} <- type.dump(cast) do
      type.load(dumped)
    end
  end
end

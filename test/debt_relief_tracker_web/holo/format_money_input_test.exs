defmodule DebtReliefTrackerWeb.Holo.FormatMoneyInputTest do
  use ExUnit.Case, async: true

  alias DebtReliefTrackerWeb.Holo.Format

  test "parse_cents does dollars->cents with integer math" do
    assert Format.parse_cents("12.34") == {:ok, 1234}
    assert Format.parse_cents("12.3") == {:ok, 1230}
    assert Format.parse_cents("12") == {:ok, 1200}
    assert Format.parse_cents(".5") == {:ok, 50}
    assert Format.parse_cents("12.") == {:ok, 1200}
    assert Format.parse_cents("$1,234.56") == {:ok, 123_456}
    assert Format.parse_cents("-5.25") == {:ok, -525}
    assert Format.parse_cents("0.00") == {:ok, 0}
  end

  test "parse_cents rounds half up past two decimals" do
    assert Format.parse_cents("1.005") == {:ok, 101}
    assert Format.parse_cents("1.004") == {:ok, 100}
    assert Format.parse_cents("1.999") == {:ok, 200}
  end

  test "blank is nil and junk is :error" do
    assert Format.parse_cents("") == {:ok, nil}
    assert Format.parse_cents("  ") == {:ok, nil}
    assert Format.parse_cents("abc") == :error
    assert Format.parse_cents("1.2.3") == :error
    assert Format.parse_cents("1e3") == :error
    assert Format.parse_cents(".") == :error
    assert Format.parse_cents("-") == :error
  end

  test "parse_scaled handles percents and fractions (basis points)" do
    assert Format.parse_scaled("24.99", 2) == {:ok, 2499}
    assert Format.parse_scaled("0.02", 4) == {:ok, 200}
    assert Format.parse_scaled("0.0225", 4) == {:ok, 225}
    assert Format.parse_scaled("15", 0) == {:ok, 15}
  end

  test "to_plain / cents_input round-trip into input text" do
    assert Format.cents_input(450_000) == "4500.00"
    assert Format.cents_input(5) == "0.05"
    assert Format.cents_input(-525) == "-5.25"
    assert Format.cents_input(nil) == ""
    assert Format.to_plain(2499, 2) == "24.99"
    assert Format.to_plain(200, 4, 2) == "0.02"
    assert Format.to_plain(225, 4, 2) == "0.0225"
    assert Format.to_plain(2000, 4, 2) == "0.20"

    for cents <- [0, 1, 99, 100, 123_456, 100_000_000] do
      assert Format.parse_cents(Format.cents_input(cents)) == {:ok, cents}
    end
  end
end

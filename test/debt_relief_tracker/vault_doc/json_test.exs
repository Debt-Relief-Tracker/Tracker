defmodule DebtReliefTracker.VaultDoc.JsonTest do
  use ExUnit.Case, async: true

  alias DebtReliefTracker.VaultDoc.Json

  # Shared with the browser test (same data, same assertions in the page).
  def tricky do
    %{
      "unicode" => "Zoë's Kreditkarte – 日本語 😀 \u00e9",
      "quotes" => "she said \"hi\" and \\ left",
      "controls" => "line1\nline2\r\n\ttab\u0000nul\u001f\u007f",
      "sixty" => String.duplicate("N", 60),
      "empty" => "",
      "nil" => nil,
      "bools" => [true, false],
      "big" => 999_999_999_999_999,
      "neg" => -999_999_999_999_999,
      "zero" => 0,
      "list" => [1, [2, [3, []]], %{}],
      "deep" => %{"a" => %{"b" => %{"c" => %{"d" => [%{"e" => "x\"y"}]}}}},
      "slash/key" => "/",
      "ключ" => "значение"
    }
  end

  test "round-trips tricky data and is deterministic" do
    data = tricky()
    text = Json.encode(data)
    assert {:ok, ^data} = Json.decode(text)
    assert Json.encode(data) == text
    # sorted keys, no whitespace
    assert String.starts_with?(text, ~s({"big":999999999999999,"bools":[true,false],"controls":))
    refute String.contains?(text, "\n")
  end

  test "agrees with Jason on what it accepts (strings, ints, nesting)" do
    data = tricky()
    assert {:ok, ^data} = Json.decode(Jason.encode!(data))
    assert Jason.decode!(Json.encode(data)) == data
  end

  test "atom keys encode as their names; output equals string keys" do
    assert Json.encode(%{b: 1, a: nil}) == ~s({"a":null,"b":1})
  end

  test "escapes control characters and leaves unicode raw" do
    assert Json.encode("a\u0001\u001f\b\f\"") == ~s("a\\u0001\\u001F\\b\\f\\"")
    assert Json.encode("é😀") == ~s("é😀")
  end

  test "decodes \\u escapes and surrogate pairs" do
    assert {:ok, "é😀/"} = Json.decode(~s("\\u00e9\\ud83d\\ude00\\/"))
    assert {:ok, "\u0000"} = Json.decode(~s("\\u0000"))
  end

  test "decodes whitespace-formatted JSON" do
    assert {:ok, %{"a" => [1, 2]}} = Json.decode(~s( {\n "a" : [ 1 , 2 ]\t} \r\n))
  end

  test "rejects malformed input without raising" do
    bad = [
      "",
      " ",
      "{",
      "}",
      "[1,]",
      "[,1]",
      "{\"a\":}",
      "{\"a\" 1}",
      "{a:1}",
      "{\"a\":1,}",
      "1.5",
      "1e3",
      "01",
      "-",
      "-0",
      "+1",
      "tru",
      "nul",
      "True",
      "NaN",
      "\"abc",
      "abc\"",
      "\"a\nb\"",
      "\"\\x\"",
      "\"\\u12\"",
      "\"\\ud800\"",
      "\"\\udc00\"",
      "\"\\ud83d\\u0041\"",
      "[1] [2]",
      "[1] x",
      "{\"a\":1,\"a\":2}",
      "1234567890123456789",
      "\"\\",
      <<34, 255, 34>>
    ]

    for text <- bad, do: assert({text, {:error, :invalid}} == {text, Json.decode(text)})
    assert {:error, :invalid} = Json.decode(nil)
    assert {:error, :invalid} = Json.decode(123)
  end

  test "bounds nesting depth at 64 and string size at 1 MiB" do
    ok = String.duplicate("[", 64) <> String.duplicate("]", 64)
    too_deep = String.duplicate("[", 65) <> String.duplicate("]", 65)
    assert {:ok, _} = Json.decode(ok)
    assert {:error, :invalid} = Json.decode(too_deep)

    obj = String.duplicate("{\"a\":", 65) <> "1" <> String.duplicate("}", 65)
    assert {:error, :invalid} = Json.decode(obj)

    big = String.duplicate("a", 1_048_576)
    assert {:ok, ^big} = Json.decode(~s("#{big}"))
    assert {:error, :invalid} = Json.decode(~s("#{big}a"))

    # a long string made of escapes is bounded too
    assert {:error, :invalid} = Json.decode(~s("#{String.duplicate("\\n", 600_000)}"))
  end

  test "bounds the whole input" do
    huge = "[" <> String.duplicate("1,", 9_000_000) <> "1]"
    assert {:error, :invalid} = Json.decode(huge)
  end

  test "encode raises on floats and unsupported terms (programmer errors)" do
    assert_raise ArgumentError, fn -> Json.encode(1.5) end
    assert_raise ArgumentError, fn -> Json.encode({1, 2}) end
    assert_raise ArgumentError, fn -> Json.encode(%{1 => 2}) end
  end

  test "random strings round-trip" do
    :rand.seed(:exsss, {7, 8, 9})
    alphabet = Enum.concat([Enum.to_list(0..127), [233, 8364, 128_512, 0x10FFFF, 0x2028]])

    for _ <- 1..300 do
      len = :rand.uniform(40) - 1
      str = for(_ <- 1..max(len, 1), do: Enum.random(alphabet)) |> List.to_string()
      assert {:ok, ^str} = Json.decode(Json.encode(str))
      assert {:ok, %{"k" => [^str]}} = Json.decode(Json.encode(%{"k" => [str]}))
    end
  end
end

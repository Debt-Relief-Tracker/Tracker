defmodule DebtReliefTracker.VaultDoc.Json do
  @moduledoc """
  Deterministic JSON for the vault document (client-safe).

  ## Approach: a pure Elixir reference + a JS fast path, proven identical

  Jason is not available in the browser, so the codec is written in pure
  Elixir (`encode_pure/1`, `decode_pure/1`): the reference implementation,
  used on the server and by ExUnit. It is correct in the browser too (it is
  compiled by Hologram and the browser test runs it), but Hologram's
  interpreter makes it unusably slow on a real document: every `[h | t]`
  match, cons, `Map.put` and most recursive `Enum` functions copy their whole
  list/map (measured: 1000 cons cells ~35 ms, 1000 `Map.put`s ~350 ms,
  `Enum.join` of 1000 strings ~220 ms, `String.codepoints` of 4 KB effectively
  hangs), and each function call costs ~100 us. The pure decoder therefore
  only uses linear operations (`Enum.map`/`for`, `:lists` folds, `Map.new`,
  `IO.iodata_to_binary`, `String.split`/`replace`, `elem/2`) and still needed
  ~13 s per 900 records.

  So in the browser `encode/1` and `decode/1` call
  `assets/js/vault_json_facade.mjs` (a ~200-line generic canonical-JSON
  encoder and strict parser, no application logic; ~70 ms for 5,000 records)
  through JS interop, and fall back to the pure code when JS interop is a
  no-op (the server) or throws. `JSON.parse`/`JSON.stringify` are *not* used
  directly because they cannot give the guarantees below: `stringify` keeps
  insertion order, `parse` turns every number into a double (silently
  rounding integers above 2^53), accepts duplicate keys and floats, and is
  unbounded. The facade is a strict re-implementation of the same grammar and
  limits, and `test/debt_relief_tracker/vault_doc/vault_doc_browser_test.exs`
  compares the facade's output with the BEAM's pure output byte for byte on a
  fixed script (and runs both codecs in the browser on tricky data), which is
  the proof that the two cannot drift. It needs no `eval`.

  ## Format

  `encode/1` takes `nil`, booleans, integers, binaries, lists and maps whose
  keys are binaries or atoms (atoms are written as their name); it never
  emits floats (floats raise `ArgumentError`). Output has no whitespace, map
  keys are sorted by their UTF-8 bytes, strings are written as UTF-8 with
  only `"`, `\\` and U+0000..U+001F escaped (`\\n \\r \\t \\b \\f`, the rest as
  `\\u00xx`).

  `decode/1` accepts standard JSON without floats (no `.`/exponent numbers)
  and returns `{:ok, term}` with binary keys, or `{:error, :invalid}` for
  anything malformed, a float, a duplicate object key, an unpaired surrogate
  escape, a raw control character in a string, nesting deeper than
  #{64}, a string longer than 1 MiB or input larger than 16 MiB. Integers are
  limited to +-(2^53 - 1).
  """

  use Hologram.JS

  js_import from: "../../../assets/js/vault_json_facade.mjs", as: :VaultJsonFacade

  @max_depth 64
  @max_string_bytes 1_048_576
  @max_input_bytes 16_777_216
  @max_int 9_007_199_254_740_991
  @max_int_digits 16

  @escapes (for code <- Enum.to_list(0..31), into: %{} do
              {List.to_string([code]),
               case code do
                 8 ->
                   "\\b"

                 9 ->
                   "\\t"

                 10 ->
                   "\\n"

                 12 ->
                   "\\f"

                 13 ->
                   "\\r"

                 _ ->
                   "\\u00" <>
                     String.downcase(String.pad_leading(Integer.to_string(code, 16), 2, "0"))
               end}
            end)
           |> Map.put("\"", "\\\"")
           |> Map.put("\\", "\\\\")

  @escape_triggers Map.keys(@escapes)
  @raw_control_chars Map.keys(@escapes) -- ["\"", "\\"]
  @control_escapes Map.to_list(Map.drop(@escapes, ["\"", "\\"]))

  # Placeholders for an escaped backslash / escaped quote while splitting.
  @bs "\u0001"
  @qt "\u0002"

  @unescapes %{
    "\"" => "\"",
    "\\" => "\\",
    "/" => "/",
    "b" => "\b",
    "f" => "\f",
    "n" => "\n",
    "r" => "\r",
    "t" => "\t"
  }

  @hex %{
    "0" => 0,
    "1" => 1,
    "2" => 2,
    "3" => 3,
    "4" => 4,
    "5" => 5,
    "6" => 6,
    "7" => 7,
    "8" => 8,
    "9" => 9,
    "a" => 10,
    "b" => 11,
    "c" => 12,
    "d" => 13,
    "e" => 14,
    "f" => 15,
    "A" => 10,
    "B" => 11,
    "C" => 12,
    "D" => 13,
    "E" => 14,
    "F" => 15
  }

  # --- encode ----------------------------------------------------------------

  @doc """
  Deterministic JSON text for `term` (see the moduledoc). In the browser this
  calls the JS facade (same bytes, ~1000x faster); on the server, or if the
  facade raises, the pure implementation below runs.
  """
  @spec encode(term()) :: String.t()
  def encode(term) do
    case fast_encode(term) do
      text when is_binary(text) -> text
      _ -> encode_pure(term)
    end
  end

  defp fast_encode(term) do
    JS.call(:VaultJsonFacade, :encode, [term])
  rescue
    _ -> nil
  end

  @doc "The pure Elixir encoder (reference implementation; used on the server)."
  @spec encode_pure(term()) :: String.t()
  def encode_pure(term), do: IO.iodata_to_binary(enc(term))

  defp enc(nil), do: "null"
  defp enc(true), do: "true"
  defp enc(false), do: "false"
  defp enc(n) when is_integer(n), do: Integer.to_string(n)
  defp enc(s) when is_binary(s), do: enc_string(s)
  defp enc([]), do: "[]"

  defp enc(list) when is_list(list) do
    ["[", commas(Enum.map(list, &enc/1)), "]"]
  end

  defp enc(map) when is_map(map) do
    if map_size(map) == 0 do
      "{}"
    else
      pairs = map |> Enum.map(fn {k, v} -> {key_string(k), v} end) |> Enum.sort_by(&elem(&1, 0))
      ["{", commas(Enum.map(pairs, fn {k, v} -> [enc_string(k), ":", enc(v)] end)), "}"]
    end
  end

  defp enc(other), do: raise(ArgumentError, "cannot encode #{kind(other)} as vault JSON")

  # Comma-separated iodata of a non-empty list, without recursion on the list.
  defp commas([first | rest]), do: [first, Enum.map(rest, &[",", &1])]

  defp kind(term) when is_float(term), do: "a float"
  defp kind(term) when is_atom(term), do: "an atom"
  defp kind(term) when is_tuple(term), do: "a tuple"
  defp kind(_), do: "this term"

  defp key_string(k) when is_binary(k), do: k
  defp key_string(k) when is_atom(k), do: Atom.to_string(k)
  defp key_string(_), do: raise(ArgumentError, "JSON object keys must be strings or atoms")

  defp enc_string(s) do
    unless String.valid?(s), do: raise(ArgumentError, "cannot encode invalid UTF-8")

    if String.contains?(s, @escape_triggers) do
      ["\"", escape(s), "\""]
    else
      ["\"", s, "\""]
    end
  end

  # Whole-string replaces (linear) instead of walking code points.
  defp escape(s) do
    s = s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

    if String.contains?(s, @raw_control_chars) do
      Enum.reduce(@control_escapes, s, fn {raw, esc}, acc ->
        if String.contains?(acc, raw), do: String.replace(acc, raw, esc), else: acc
      end)
    else
      s
    end
  end

  # --- decode ----------------------------------------------------------------

  @doc """
  Parses JSON text without floats; `{:error, :invalid}` for anything else.
  Browser: JS facade; server (or facade unavailable): `decode_pure/1`.
  """
  @spec decode(term()) :: {:ok, term()} | {:error, :invalid}
  def decode(text) do
    case fast_decode(text) do
      [true, value] -> {:ok, value}
      [false | _] -> {:error, :invalid}
      _ -> decode_pure(text)
    end
  end

  defp fast_decode(text) when is_binary(text) do
    JS.call(:VaultJsonFacade, :decode, [text])
  rescue
    _ -> nil
  end

  defp fast_decode(_), do: nil

  @doc "The pure Elixir decoder (reference implementation; used on the server)."
  @spec decode_pure(term()) :: {:ok, term()} | {:error, :invalid}
  def decode_pure(text) when is_binary(text) do
    cond do
      byte_size(text) > @max_input_bytes or not String.valid?(text) -> {:error, :invalid}
      String.contains?(text, [@bs, @qt]) -> {:error, :invalid}
      true -> text |> protect() |> tokens() |> parse()
    end
  end

  def decode_pure(_), do: {:error, :invalid}

  # \\ and \" become single placeholder characters (raw U+0001/U+0002 never
  # occur in valid JSON, rejected above), so every remaining `"` delimits a
  # string and every remaining backslash starts some other escape.
  defp protect(text) do
    text |> String.replace("\\\\", @bs) |> String.replace("\\\"", @qt)
  end

  defp tokens(text) do
    pieces = String.split(text, "\"")

    if rem(length(pieces), 2) == 1 do
      tuple = List.to_tuple(pieces)

      lists =
        for i <- 0..(tuple_size(tuple) - 1) do
          if rem(i, 2) == 0, do: lex_outside(elem(tuple, i)), else: [string_token(elem(tuple, i))]
        end

      {:ok, :lists.flatten(lists)}
    else
      :error
    end
  end

  defp string_token(body) do
    body =
      if String.contains?(body, [@bs, @qt]),
        do: body |> String.replace(@bs, "\\\\") |> String.replace(@qt, "\\\""),
        else: body

    cond do
      byte_size(body) > @max_string_bytes -> :bad
      String.contains?(body, @raw_control_chars) -> :bad
      not String.contains?(body, "\\") -> {:str, body}
      true -> unescape(body)
    end
  end

  # Tokens of a piece outside any string. Structural characters are padded
  # with spaces, then the piece is split into words.
  defp lex_outside(piece) do
    words =
      piece
      |> String.replace("{", " { ")
      |> String.replace("}", " } ")
      |> String.replace("[", " [ ")
      |> String.replace("]", " ] ")
      |> String.replace(",", " , ")
      |> String.replace(":", " : ")
      |> String.split()

    Enum.map(words, &word/1)
  end

  defp word("{"), do: :obj_open
  defp word("}"), do: :obj_close
  defp word("["), do: :arr_open
  defp word("]"), do: :arr_close
  defp word(","), do: :comma
  defp word(":"), do: :colon
  defp word("true"), do: true
  defp word("false"), do: false
  defp word("null"), do: :null

  defp word(run) do
    {sign, digits} =
      if String.starts_with?(run, "-"),
        do: {-1, String.slice(run, 1, String.length(run))},
        else: {1, run}

    if digits != "" and String.length(digits) <= @max_int_digits and
         DebtReliefTracker.VaultDoc.Stamp.digits?(digits) and
         (digits == "0" or not String.starts_with?(digits, "0")) and
         not (sign == -1 and digits == "0") do
      n = sign * String.to_integer(digits)
      if abs(n) <= @max_int, do: {:int, n}, else: :bad
    else
      :bad
    end
  end

  defp unescape(body) do
    cps = List.to_tuple(String.codepoints(body))
    unescape_loop(cps, 0, tuple_size(cps), [])
  end

  # String bodies with escapes are short in practice (names, notes); the
  # accumulator is bounded by the 1 MiB string limit.
  defp unescape_loop(_cps, i, size, acc) when i >= size,
    do: {:str, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp unescape_loop(cps, i, size, acc) do
    case elem(cps, i) do
      "\\" when i + 1 < size ->
        esc = elem(cps, i + 1)

        cond do
          Map.has_key?(@unescapes, esc) ->
            unescape_loop(cps, i + 2, size, [Map.fetch!(@unescapes, esc) | acc])

          esc == "u" ->
            case read_unicode(cps, i + 2, size) do
              {:ok, str, next} -> unescape_loop(cps, next, size, [str | acc])
              :error -> :bad
            end

          true ->
            :bad
        end

      "\\" ->
        :bad

      cp ->
        unescape_loop(cps, i + 1, size, [cp | acc])
    end
  end

  # \uXXXX at cps[i..i+3], with surrogate pairs.
  defp read_unicode(cps, i, size) do
    with {:ok, hi} <- hex4(cps, i, size) do
      cond do
        hi >= 0xD800 and hi <= 0xDBFF ->
          if i + 10 <= size and elem(cps, i + 4) == "\\" and elem(cps, i + 5) == "u" do
            with {:ok, lo} <- hex4(cps, i + 6, size),
                 true <- lo >= 0xDC00 and lo <= 0xDFFF do
              {:ok, List.to_string([0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00)]), i + 10}
            else
              _ -> :error
            end
          else
            :error
          end

        hi >= 0xDC00 and hi <= 0xDFFF ->
          :error

        true ->
          {:ok, List.to_string([hi]), i + 4}
      end
    end
  end

  defp hex4(cps, i, size) do
    if i + 4 <= size do
      Enum.reduce_while(0..3, {:ok, 0}, fn k, {:ok, acc} ->
        case Map.fetch(@hex, elem(cps, i + k)) do
          {:ok, v} -> {:cont, {:ok, acc * 16 + v}}
          :error -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  # --- parse -----------------------------------------------------------------

  defp parse(:error), do: {:error, :invalid}

  defp parse({:ok, tokens}) do
    # Depth of every token: openers and the tokens inside a container carry
    # the container's level (1 = outermost), closers the level outside it.
    {deps, final} =
      :lists.mapfoldl(
        fn
          tok, d when tok == :obj_open or tok == :arr_open -> {d + 1, d + 1}
          tok, d when tok == :obj_close or tok == :arr_close -> {d - 1, d - 1}
          _tok, d -> {d, d}
        end,
        0,
        tokens
      )

    cond do
      tokens == [] or final != 0 ->
        {:error, :invalid}

      :lists.member(:bad, tokens) ->
        {:error, :invalid}

      Enum.min(deps) < 0 or Enum.max(deps) > @max_depth ->
        {:error, :invalid}

      true ->
        toks = List.to_tuple(tokens)
        ds = List.to_tuple(deps)

        case value(toks, ds, 0, tuple_size(toks) - 1) do
          {:ok, v} -> {:ok, v}
          :error -> {:error, :invalid}
        end
    end
  end

  # The value spanning tokens a..b (inclusive).
  defp value(_toks, _ds, a, b) when a > b, do: :error

  defp value(toks, ds, a, b) do
    case elem(toks, a) do
      {:str, s} -> scalar(a, b, s)
      {:int, n} -> scalar(a, b, n)
      true -> scalar(a, b, true)
      false -> scalar(a, b, false)
      :null -> scalar(a, b, nil)
      :arr_open -> container(toks, ds, a, b, :arr_close, &array/4)
      :obj_open -> container(toks, ds, a, b, :obj_close, &object/4)
      _ -> :error
    end
  end

  defp scalar(a, b, v), do: if(a == b, do: {:ok, v}, else: :error)

  # a..b must be an opener and its matching closer with only deeper tokens between.
  defp container(toks, ds, a, b, closer, build) do
    level = elem(ds, a)

    cond do
      b <= a or elem(toks, b) != closer or elem(ds, b) != level - 1 ->
        :error

      b == a + 1 ->
        build.(toks, ds, [], level)

      true ->
        inside = for k <- (a + 1)..(b - 1), do: elem(ds, k)

        if Enum.min(inside) < level do
          :error
        else
          commas =
            for k <- (a + 1)..(b - 1), elem(ds, k) == level and elem(toks, k) == :comma, do: k

          bounds = List.to_tuple([a | commas] ++ [b])

          build.(
            toks,
            ds,
            for(
              i <- 0..(tuple_size(bounds) - 2),
              do: {elem(bounds, i) + 1, elem(bounds, i + 1) - 1}
            ),
            level
          )
        end
    end
  end

  defp array(_toks, _ds, [], _level), do: {:ok, []}

  defp array(toks, ds, ranges, _level) do
    results = for {from, to} <- ranges, do: value(toks, ds, from, to)

    if :lists.member(:error, results),
      do: :error,
      else: {:ok, for({:ok, v} <- results, do: v)}
  end

  defp object(_toks, _ds, [], _level), do: {:ok, %{}}

  defp object(toks, ds, ranges, _level) do
    results =
      for {from, to} <- ranges do
        with true <- to >= from + 2,
             {:str, key} <- elem(toks, from),
             :colon <- elem(toks, from + 1),
             {:ok, v} <- value(toks, ds, from + 2, to) do
          {:ok, {key, v}}
        else
          _ -> :error
        end
      end

    if :lists.member(:error, results) do
      :error
    else
      map = Map.new(for {:ok, pair} <- results, do: pair)
      if map_size(map) == length(results), do: {:ok, map}, else: :error
    end
  end
end

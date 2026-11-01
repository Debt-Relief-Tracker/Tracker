defmodule DebtReliefTracker.VaultDoc.Json do
  @moduledoc """
  Deterministic JSON for the vault document, in pure Elixir (client-safe).

  ## Why not Jason or `JS.call(:JSON, ...)`

  Jason is not available in the browser (it is not ported and uses
  floats/binary matching Hologram has not got). `JSON.parse` /
  `JSON.stringify` through Hologram's JS interop were rejected because:

    * the document must be encoded to *the same bytes* on every device and
      on the server (tests compare browser output with ExUnit output byte for
      byte); `JSON.stringify` keeps insertion order and renders non-integers
      and `-0` its own way, and `JSON.parse` turns every number into a double
      (silently rounding integers above 2^53), while Hologram's interop
      conversion of a parsed object (plain object <-> map, number <->
      float/integer) is exactly the kind of boundary this app wants to keep
      out of its data path;
    * the decoder has to be bounded (nesting, string size) and must never
      throw into the UI; doing that by wrapping a throwing native parser
      still leaves the conversion step unbounded;
    * it keeps "no application logic in JS" and the CSP (no `eval`) trivially
      true.

  The price is speed, handled by working on whole strings rather than single
  characters (Hologram lists and bitstrings copy on every cons/tail match,
  so a char-by-char descent is quadratic): the decoder splits the text on
  `"` once, so string bodies are never walked unless they contain a
  backslash, and it parses a token tuple by index.

  ## Format

  `encode/1` takes `nil`, booleans, integers, binaries, lists and maps whose
  keys are binaries or atoms (atoms are written as their name); it never
  emits floats (floats raise `ArgumentError`). Output has no whitespace, map
  keys are sorted by their UTF-8 bytes, strings are written as UTF-8 with
  only `"`, `\\` and U+0000..U+001F escaped (`\\n \\r \\t \\b \\f`, the rest as
  `\\u00XX`).

  `decode/1` accepts standard JSON without floats (no `.`/exponent numbers)
  and returns `{:ok, term}` with binary keys, or `{:error, :invalid}` for
  anything malformed, a float, a duplicate object key, an unpaired surrogate
  escape, a raw control character in a string, nesting deeper than
  #{64}, a string longer than 1 MiB or input larger than 16 MiB. Integers are
  limited to 18 digits.
  """

  @max_depth 64
  @max_string_bytes 1_048_576
  @max_input_bytes 16_777_216
  @max_int_digits 18

  @escapes (for code <- Enum.to_list(0..31), into: %{} do
              {List.to_string([code]),
               case code do
                 8 -> "\\b"
                 9 -> "\\t"
                 10 -> "\\n"
                 12 -> "\\f"
                 13 -> "\\r"
                 _ -> "\\u00" <> String.upcase(String.pad_leading(Integer.to_string(code, 16), 2, "0"))
               end}
            end)
            |> Map.put("\"", "\\\"")
            |> Map.put("\\", "\\\\")

  @escape_triggers Map.keys(@escapes)
  @raw_control_chars Map.keys(@escapes) -- ["\"", "\\"]

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

  @doc "Deterministic JSON text for `term` (see the moduledoc)."
  @spec encode(term()) :: String.t()
  def encode(term), do: term |> enc([]) |> Enum.reverse() |> Enum.join()

  defp enc(nil, acc), do: ["null" | acc]
  defp enc(true, acc), do: ["true" | acc]
  defp enc(false, acc), do: ["false" | acc]
  defp enc(n, acc) when is_integer(n), do: [Integer.to_string(n) | acc]
  defp enc(s, acc) when is_binary(s), do: [enc_string(s) | acc]
  defp enc([], acc), do: ["[]" | acc]

  defp enc(list, acc) when is_list(list) do
    inner =
      Enum.reduce(list, {true, ["[" | acc]}, fn item, {first?, acc} ->
        acc = if first?, do: acc, else: ["," | acc]
        {false, enc(item, acc)}
      end)
      |> elem(1)

    ["]" | inner]
  end

  defp enc(map, acc) when is_map(map) do
    pairs = map |> Enum.map(fn {k, v} -> {key_string(k), v} end) |> Enum.sort_by(&elem(&1, 0))

    inner =
      Enum.reduce(pairs, {true, ["{" | acc]}, fn {k, v}, {first?, acc} ->
        acc = if first?, do: acc, else: ["," | acc]
        {false, enc(v, [":", enc_string(k) | acc])}
      end)
      |> elem(1)

    ["}" | inner]
  end

  defp enc(other, _acc),
    do: raise(ArgumentError, "cannot encode #{kind(other)} as vault JSON")

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
      "\"" <> Enum.map_join(String.codepoints(s), &Map.get(@escapes, &1, &1)) <> "\""
    else
      "\"" <> s <> "\""
    end
  end

  # --- decode ----------------------------------------------------------------

  @doc "Parses JSON text without floats; `{:error, :invalid}` for anything else."
  @spec decode(term()) :: {:ok, term()} | {:error, :invalid}
  def decode(text) when is_binary(text) do
    if byte_size(text) > @max_input_bytes or not String.valid?(text) do
      {:error, :invalid}
    else
      with {:ok, tokens} <- tokenize(text),
           toks = List.to_tuple(tokens),
           {:ok, value, next} <- parse_value(toks, 0, 0),
           true <- next == tuple_size(toks) do
        {:ok, value}
      else
        _ -> {:error, :invalid}
      end
    end
  end

  def decode(_), do: {:error, :invalid}

  # Splits on `"`: even-numbered pieces are outside strings, odd-numbered are
  # string bodies (a body ending in an odd number of backslashes ended at an
  # escaped quote and continues in the next piece).
  defp tokenize(text) do
    result =
      Enum.reduce_while(String.split(text, "\""), {:outside, "", []}, fn piece, {mode, buf, toks} ->
        case mode do
          :outside ->
            case lex_outside(piece) do
              {:ok, new} -> {:cont, {:string, "", new ++ toks}}
              :error -> {:halt, :error}
            end

          :string ->
            body = buf <> piece

            cond do
              byte_size(body) > @max_string_bytes ->
                {:halt, :error}

              odd_trailing_backslashes?(piece) ->
                {:cont, {:string, body <> "\"", toks}}

              true ->
                case unescape(body) do
                  {:ok, str} -> {:cont, {:outside, "", [{:str, str} | toks]}}
                  :error -> {:halt, :error}
                end
            end
        end
      end)

    case result do
      # Finished in :string mode = the last piece was outside (a quote count
      # of 2n gives 2n+1 pieces, so the last piece is outside and the mode
      # afterwards is :string); finishing in :outside means an unclosed string.
      {:string, "", toks} -> {:ok, Enum.reverse(toks)}
      _ -> :error
    end
  end

  defp odd_trailing_backslashes?(piece) do
    if String.ends_with?(piece, "\\") do
      trailing = String.length(piece) - String.length(String.trim_trailing(piece, "\\"))
      rem(trailing, 2) == 1
    else
      false
    end
  end

  # Tokens for a piece outside any string, REVERSED (so they prepend onto acc).
  defp lex_outside(piece) do
    result =
      Enum.reduce_while(String.codepoints(piece), {"", []}, fn cp, {run, toks} ->
        token = punct(cp)

        cond do
          token != nil ->
            case close_run(run, toks) do
              {:ok, toks} -> {:cont, {"", [token | toks]}}
              :error -> {:halt, :error}
            end

          cp == " " or cp == "\n" or cp == "\t" or cp == "\r" ->
            case close_run(run, toks) do
              {:ok, toks} -> {:cont, {"", toks}}
              :error -> {:halt, :error}
            end

          run_char?(cp) ->
            {:cont, {run <> cp, toks}}

          true ->
            {:halt, :error}
        end
      end)

    case result do
      :error -> :error
      {run, toks} -> close_run(run, toks)
    end
  end

  # Closes the pending number/literal run (if any).
  defp close_run("", toks), do: {:ok, toks}

  defp close_run(run, toks) do
    case literal(run) do
      {:ok, token} -> {:ok, [token | toks]}
      :error -> :error
    end
  end

  defp punct("{"), do: :obj_open
  defp punct("}"), do: :obj_close
  defp punct("["), do: :arr_open
  defp punct("]"), do: :arr_close
  defp punct(","), do: :comma
  defp punct(":"), do: :colon
  defp punct(_), do: nil

  defp run_char?(cp), do: cp == "-" or (cp >= "0" and cp <= "9") or (cp >= "a" and cp <= "z")

  defp literal("true"), do: {:ok, true}
  defp literal("false"), do: {:ok, false}
  defp literal("null"), do: {:ok, :null}

  defp literal(run) do
    {sign, digits} =
      if String.starts_with?(run, "-"), do: {-1, String.slice(run, 1, String.length(run))}, else: {1, run}

    if digits != "" and String.length(digits) <= @max_int_digits and
         DebtReliefTracker.VaultDoc.Stamp.digits?(digits) and
         (digits == "0" or not String.starts_with?(digits, "0")) and
         not (sign == -1 and digits == "0") do
      {:ok, {:int, sign * String.to_integer(digits)}}
    else
      :error
    end
  end

  defp unescape(body) do
    cond do
      String.contains?(body, @raw_control_chars) ->
        :error

      not String.contains?(body, "\\") ->
        {:ok, body}

      true ->
        cps = List.to_tuple(String.codepoints(body))
        unescape_loop(cps, 0, tuple_size(cps), [])
    end
  end

  defp unescape_loop(_cps, i, size, acc) when i >= size,
    do: {:ok, acc |> Enum.reverse() |> Enum.join()}

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
              :error -> :error
            end

          true ->
            :error
        end

      "\\" ->
        :error

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

  defp token_at(toks, i), do: if(i < tuple_size(toks), do: elem(toks, i), else: :eof)

  defp parse_value(toks, i, depth) do
    case token_at(toks, i) do
      {:str, s} -> {:ok, s, i + 1}
      {:int, n} -> {:ok, n, i + 1}
      true -> {:ok, true, i + 1}
      false -> {:ok, false, i + 1}
      :null -> {:ok, nil, i + 1}
      :arr_open when depth < @max_depth -> parse_array(toks, i + 1, depth + 1)
      :obj_open when depth < @max_depth -> parse_object(toks, i + 1, depth + 1)
      _ -> :error
    end
  end

  defp parse_array(toks, i, depth) do
    case token_at(toks, i) do
      :arr_close -> {:ok, [], i + 1}
      _ -> parse_elements(toks, i, depth, [])
    end
  end

  defp parse_elements(toks, i, depth, acc) do
    with {:ok, value, next} <- parse_value(toks, i, depth) do
      case token_at(toks, next) do
        :comma -> parse_elements(toks, next + 1, depth, [value | acc])
        :arr_close -> {:ok, Enum.reverse([value | acc]), next + 1}
        _ -> :error
      end
    end
  end

  defp parse_object(toks, i, depth) do
    case token_at(toks, i) do
      :obj_close -> {:ok, %{}, i + 1}
      _ -> parse_members(toks, i, depth, %{})
    end
  end

  defp parse_members(toks, i, depth, acc) do
    with {:str, key} <- token_at(toks, i),
         false <- Map.has_key?(acc, key),
         :colon <- token_at(toks, i + 1),
         {:ok, value, next} <- parse_value(toks, i + 2, depth) do
      acc = Map.put(acc, key, value)

      case token_at(toks, next) do
        :comma -> parse_members(toks, next + 1, depth, acc)
        :obj_close -> {:ok, acc, next + 1}
        _ -> :error
      end
    else
      _ -> :error
    end
  end
end

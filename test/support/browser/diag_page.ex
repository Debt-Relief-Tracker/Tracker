defmodule DebtReliefTracker.BrowserCase.DiagPage do
  use Hologram.Page
  use Hologram.JS
  alias DebtReliefTracker.VaultDoc
  alias DebtReliefTracker.VaultDoc.{Json, Ledger, Stamp}

  route "/__browser_test/diag"
  layout DebtReliefTrackerWeb.Holo.Layout
  def init(_p, c, _s), do: put_state(c, :out, "")

  def template do
    ~HOLO"""
    <div id="diag"><button id="go" $click="go">go</button><pre id="out">{@out}</pre></div>
    """
  end

  defp now, do: JS.call(:Date, :now, [])

  defp t(label, fun) do
    t0 = now()
    r = try do inspect(fun.(), limit: 5, printable_limit: 80) rescue e -> "RAISED " <> inspect(e) end
    line = label <> ": " <> r <> " (" <> Integer.to_string(now() - t0) <> "ms)\n"
    JS.set(:window, :__log, (JS.get(:window, :__log) || "") <> line)
    line
  end

  def action(:go, _p, c) do
    DebtReliefTrackerWeb.Holo.QuietJS.quiet()
    ctx = %{now: "2026-11-01T12:00:00Z", today: "2026-11-10", new_id: fn -> "x" <> Integer.to_string(now()) end, actor: nil, members: nil}
    JS.set(:window, :__log, "")
    out = ""
    for n <- [4000] do
      l = Enum.to_list(1..n)
      pairs = Enum.map(l, &{Integer.to_string(&1), &1})
      m = Map.new(pairs)
      strs = Enum.map(l, &Integer.to_string/1)
      big = Enum.join(strs, ",")
      k = Integer.to_string(n)
      t("sort_by#{k}", fn -> Enum.sort_by(l, &(-&1)) |> length() end)
      t("map_new2#{k}", fn -> Map.new(l, &{&1, &1}) |> map_size() end)
      t("map_merge3_#{k}", fn -> Map.merge(m, m, fn _, a, _ -> a end) |> map_size() end)
      t("iodata#{k}", fn -> IO.iodata_to_binary(Enum.map(strs, &[&1, ","])) |> byte_size() end)
      t("elem_loop#{k}", fn -> tp = List.to_tuple(l); Enum.reduce(0..(n - 1), 0, fn i, a -> a + elem(tp, i) end) end)
      t("flatten#{k}", fn -> :lists.flatten(Enum.map(l, &[&1, [&1]])) |> length() end)
      t("mapfoldl#{k}", fn -> :lists.mapfoldl(fn x, a -> {a, a + x} end, 0, l) |> elem(1) end)
      t("split#{k}", fn -> String.split(big, ",") |> length() end)
      t("concat_acc#{k}", fn -> Enum.reduce(strs, "", &(&2 <> &1)) |> byte_size() end)
      t("sort#{k}", fn -> Enum.sort(strs) |> length() end)
      t("keysort#{k}", fn -> Enum.sort_by(pairs, &elem(&1, 0)) |> length() end)
      t("tuple_sort#{k}", fn -> Enum.sort_by(l, &{-&1, "x"}) |> length() end)
      t("map_take#{k}", fn -> Map.take(m, Enum.take(strs, 10)) |> map_size() end)
      t("map_drop#{k}", fn -> Map.drop(m, Enum.take(strs, 10)) |> map_size() end)
      t("map_put1#{k}", fn -> Map.put(m, "zz", 1) |> map_size() end)
      t("enum_into_map#{k}", fn -> Enum.into(pairs, %{}) |> map_size() end)
    end
    put_state(c, :out, out)
  end
end

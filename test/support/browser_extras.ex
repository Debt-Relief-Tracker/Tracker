defmodule DebtReliefTracker.BrowserExtras do
  @moduledoc """
  Extra helpers for `DebtReliefTracker.BrowserCase` tests (viewport, keys,
  selects, page-side evaluation). Import next to `use BrowserCase`.
  """

  alias DebtReliefTracker.BrowserCase.Driver

  def set_viewport(%{driver: d} = ctx, width, height \\ 800) do
    Driver.call(d, "viewport", %{width: width, height: height})
    ctx
  end

  @doc "Console errors / page errors / 5xx responses seen so far."
  def errors(%{driver: d}), do: Driver.call(d, "errors", %{})

  @doc "Clicks `selector` at an offset (px) from its top-left corner."
  def click_at(%{driver: d} = ctx, selector, x, y) do
    Driver.call(d, "click_at", %{selector: selector, x: x, y: y})
    ctx
  end

  def press(%{driver: d} = ctx, key) do
    Driver.call(d, "press", %{key: key})
    ctx
  end

  def select_option(%{driver: d} = ctx, selector, value) do
    Driver.call(d, "select_option", %{selector: selector, value: value})
    ctx
  end

  @doc "Evaluates a JS expression in the page and returns its JSON-decoded value."
  def js(%{driver: d}, expr), do: Driver.call(d, "eval", %{expr: expr})

  def count(%{driver: d}, selector), do: Driver.call(d, "count", %{selector: selector})

  @doc "Value of an input/select, or nil when absent."
  def value(ctx, selector),
    do: js(ctx, "document.querySelector(#{JSON.encode!(selector)})?.value ?? null")

  @doc "`%{\"x\",\"y\",\"w\",\"h\",\"r\",\"b\"}` bounding box of the first match, or nil."
  def rect(ctx, selector) do
    js(ctx, """
    (() => { const e = document.querySelector(#{JSON.encode!(selector)}); if (!e) return null;
      const r = e.getBoundingClientRect();
      return {x: r.left, y: r.top, w: r.width, h: r.height, r: r.right, b: r.bottom}; })()
    """)
  end

  @doc "True once `expr` (JS) is truthy; polls up to ~10s, raises otherwise."
  def wait_js(ctx, expr, tries \\ 100) do
    cond do
      js(ctx, expr) ->
        ctx

      tries == 0 ->
        raise "timeout waiting for JS: #{expr}"

      true ->
        Process.sleep(100)
        wait_js(ctx, expr, tries - 1)
    end
  end

  @doc "Viewport size as `{w, h}`."
  def viewport(ctx) do
    %{"w" => w, "h" => h} = js(ctx, "({w: innerWidth, h: innerHeight})")
    {w, h}
  end

  @doc "True when the page scrolls horizontally."
  def h_overflow?(ctx),
    do: js(ctx, "document.documentElement.scrollWidth > document.documentElement.clientWidth + 1")
end

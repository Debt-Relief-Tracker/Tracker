defmodule DebtReliefTrackerWeb.UmamiScriptTest do
  use DebtReliefTrackerWeb.ConnCase, async: false

  setup do
    original = Application.get_env(:debt_relief_tracker, :umami)

    on_exit(fn -> Application.put_env(:debt_relief_tracker, :umami, original) end)
  end

  defp script_tags(conn) do
    conn
    |> html_response(200)
    |> LazyHTML.from_document()
    |> LazyHTML.query("script[data-website-id]")
  end

  test "renders the Umami script when configured", %{conn: conn} do
    Application.put_env(:debt_relief_tracker, :umami,
      script_url: "https://umami.example.com/script.js",
      website_id: "site-123"
    )

    tags = conn |> get(~p"/") |> script_tags()

    assert LazyHTML.attribute(tags, "src") == ["https://umami.example.com/script.js"]
    assert LazyHTML.attribute(tags, "data-website-id") == ["site-123"]
  end

  test "renders no Umami script when unconfigured", %{conn: conn} do
    Application.put_env(:debt_relief_tracker, :umami, nil)

    assert conn |> get(~p"/") |> script_tags() |> Enum.count() == 0
  end
end

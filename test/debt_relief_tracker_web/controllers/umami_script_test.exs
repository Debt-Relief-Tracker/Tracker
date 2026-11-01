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

    tags = conn |> get("/admin") |> script_tags()

    assert LazyHTML.attribute(tags, "src") == ["https://umami.example.com/script.js"]
    assert LazyHTML.attribute(tags, "data-website-id") == ["site-123"]
  end

  test "renders no Umami script when unconfigured", %{conn: conn} do
    Application.put_env(:debt_relief_tracker, :umami, nil)

    assert conn |> get("/admin") |> script_tags() |> Enum.count() == 0
  end

  test "E2EE mode never loads the analytics script and never allows its origin", %{conn: conn} do
    Application.put_env(:debt_relief_tracker, :umami,
      script_url: "https://stats.example.com/script.js",
      website_id: "abc"
    )

    previous = Application.get_env(:debt_relief_tracker, :e2ee)
    Application.put_env(:debt_relief_tracker, :e2ee, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:debt_relief_tracker, :e2ee),
        else: Application.put_env(:debt_relief_tracker, :e2ee, previous)
    end)

    assert DebtReliefTrackerWeb.Layouts.umami_config() == nil

    conn = get(conn, "/admin")
    csp = conn |> Plug.Conn.get_resp_header("content-security-policy") |> Enum.join(" ")
    refute csp =~ "stats.example.com"
  end
end

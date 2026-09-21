defmodule DebtReliefTrackerWeb.Api.SupportEmailControllerTest do
  use DebtReliefTrackerWeb.ConnCase

  alias DebtReliefTracker.{Accounts, Support}

  setup do
    {:ok, raw_token, api_token} =
      Accounts.create_api_token(%{"name" => "Test", "scopes" => ["support_emails:write"]}, nil)

    %{raw_token: raw_token, api_token: api_token}
  end

  @valid_params %{
    "from" => "user@example.com",
    "to" => "support@debtreliefapp.com",
    "subject" => "Question about my plan",
    "body" => "Can you help me understand my payoff timeline?",
    "received_at" => "2026-09-01T12:00:00Z"
  }

  defp post_support_email(conn, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/support_emails", Jason.encode!(params))
  end

  describe "POST /api/support_emails" do
    test "logs the email and returns 201 with a valid bearer token", %{
      conn: conn,
      raw_token: raw_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> post_support_email(@valid_params)

      assert %{"id" => id, "received_at" => _} = json_response(conn, 201)
      assert [logged] = Support.list_support_emails()
      assert logged.id == id
      assert logged.subject == "Question about my plan"
    end

    test "records which token logged it", %{
      conn: conn,
      raw_token: raw_token,
      api_token: api_token
    } do
      conn
      |> put_req_header("authorization", "Bearer #{raw_token}")
      |> post_support_email(@valid_params)

      assert [logged] = Support.list_support_emails()
      assert logged.api_token_id == api_token.id
    end

    test "returns 401 with no authorization header", %{conn: conn} do
      conn = post_support_email(conn, @valid_params)
      assert json_response(conn, 401)
      assert Support.list_support_emails() == []
    end

    test "returns 401 with an invalid token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer drt_not_a_real_token")
        |> post_support_email(@valid_params)

      assert json_response(conn, 401)
    end

    test "returns 401 with a revoked token", %{
      conn: conn,
      raw_token: raw_token,
      api_token: api_token
    } do
      {:ok, _} = Accounts.revoke_api_token(api_token)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> post_support_email(@valid_params)

      assert json_response(conn, 401)
    end

    test "returns 422 when required fields are missing", %{conn: conn, raw_token: raw_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> post_support_email(%{"from" => "user@example.com"})

      assert json_response(conn, 422)
      assert Support.list_support_emails() == []
    end
  end
end

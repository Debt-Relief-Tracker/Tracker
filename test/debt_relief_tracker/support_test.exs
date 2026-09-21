defmodule DebtReliefTracker.SupportTest do
  use DebtReliefTracker.DataCase

  alias DebtReliefTracker.Support

  @valid_attrs %{
    "from" => "user@example.com",
    "to" => "support@debtreliefapp.com",
    "subject" => "Help with my payoff plan",
    "body" => "My Visa balance seems wrong, can you check?",
    "received_at" => ~U[2026-09-01 12:00:00.000000Z]
  }

  describe "log_support_email/1" do
    test "logs a support email with the given fields" do
      assert {:ok, support_email} = Support.log_support_email(@valid_attrs)

      assert support_email.from == "user@example.com"
      assert support_email.to == "support@debtreliefapp.com"
      assert support_email.subject == "Help with my payoff plan"
      assert support_email.body == "My Visa balance seems wrong, can you check?"
      assert support_email.metadata == %{}
    end

    test "accepts arbitrary metadata" do
      attrs = Map.put(@valid_attrs, "metadata", %{"ticket_id" => "123"})

      assert {:ok, support_email} = Support.log_support_email(attrs)
      assert support_email.metadata == %{"ticket_id" => "123"}
    end

    test "requires from/to/subject/body/received_at" do
      assert {:error, changeset} = Support.log_support_email(%{})

      assert %{
               from: ["can't be blank"],
               to: ["can't be blank"],
               subject: ["can't be blank"],
               body: ["can't be blank"],
               received_at: ["can't be blank"]
             } = errors_on(changeset)
    end
  end

  describe "list_support_emails/1" do
    test "lists newest received first" do
      {:ok, older} =
        Support.log_support_email(%{
          @valid_attrs
          | "received_at" => ~U[2026-01-01 00:00:00.000000Z]
        })

      {:ok, newer} =
        Support.log_support_email(%{
          @valid_attrs
          | "received_at" => ~U[2026-06-01 00:00:00.000000Z]
        })

      assert [first, second] = Support.list_support_emails()
      assert first.id == newer.id
      assert second.id == older.id
    end
  end

  describe "get_support_email!/1" do
    test "fetches by id" do
      {:ok, support_email} = Support.log_support_email(@valid_attrs)
      assert Support.get_support_email!(support_email.id).id == support_email.id
    end
  end
end

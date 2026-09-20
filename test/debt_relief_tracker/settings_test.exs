defmodule DebtReliefTracker.SettingsTest do
  use DebtReliefTracker.DataCase

  alias DebtReliefTracker.Settings

  describe "get_site_settings/0" do
    test "creates a default row on first call, idempotently" do
      site_settings1 = Settings.get_site_settings()
      site_settings2 = Settings.get_site_settings()

      assert site_settings1.id == site_settings2.id
      assert site_settings1.welcome_emails_enabled
    end
  end

  describe "update_site_settings/2" do
    test "updates the site identity fields" do
      site_settings = Settings.get_site_settings()

      assert {:ok, updated} =
               Settings.update_site_settings(site_settings, %{
                 "site_name" => "Our Tracker",
                 "from_name" => "Our Tracker",
                 "from_email" => "hello@example.com",
                 "welcome_emails_enabled" => "false"
               })

      assert updated.site_name == "Our Tracker"
      assert updated.from_email == "hello@example.com"
      refute updated.welcome_emails_enabled
    end
  end
end

defmodule DebtReliefTracker.Mailer do
  use Swoosh.Mailer, otp_app: :debt_relief_tracker

  @doc """
  Whether a real email provider is configured, i.e. mail actually leaves
  this machine. False on the Local adapter (dev's default -- README's
  "Email" section -- mail is only captured at /dev/mailbox, never sent).
  """
  def configured? do
    Application.get_env(:debt_relief_tracker, __MODULE__)[:adapter] != Swoosh.Adapters.Local
  end
end

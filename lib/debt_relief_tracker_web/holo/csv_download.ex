defmodule DebtReliefTrackerWeb.Holo.CsvDownload do
  @moduledoc """
  Elixir facade over `assets/js/csv_download.mjs`: saves a string as a file
  download in the browser (E2EE-mode CSV export). Only usable from Hologram
  actions; on the server it is a no-op.
  """

  use Hologram.JS

  js_import from: "../../../assets/js/csv_download.mjs", as: :CsvDownload

  @doc """
  Starts a download of `text` named `filename` (`text/csv`). `container` is a
  CSS selector of the open dialog the temporary anchor is clicked in (so the
  click does not count as a click outside it).
  """
  def download(filename, text, container \\ nil) do
    JS.call(:CsvDownload, :download, [filename, text, "text/csv;charset=utf-8", container])
    :ok
  end
end

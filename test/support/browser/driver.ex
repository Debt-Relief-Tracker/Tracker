defmodule DebtReliefTracker.BrowserCase.Driver do
  @moduledoc false
  # Owns the Node/Playwright child process (test/browser/driver.mjs) and speaks
  # its line-delimited JSON protocol over a Port. Synchronous request/reply.

  @dir Path.expand("../../browser", __DIR__)
  @call_timeout 30_000

  def start! do
    unless File.dir?(Path.join(@dir, "node_modules/playwright-core")) do
      raise "Playwright is not installed. Run: (cd test/browser && npm install)"
    end

    node = System.find_executable("node") || raise "node not found on PATH"

    port =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        {:line, 1_000_000},
        {:args, [Path.join(@dir, "driver.mjs")]},
        {:cd, @dir}
      ])

    {:ok, %{"ok" => true}} = read(port, 0)
    port
  end

  def stop(port) do
    Port.close(port)
  rescue
    _ -> :ok
  end

  def call(port, cmd, args) do
    id = System.unique_integer([:positive])
    Port.command(port, JSON.encode!(%{id: id, cmd: cmd, args: args}) <> "\n")

    case read(port, id) do
      {:ok, %{"ok" => true, "value" => value}} -> value
      {:ok, %{"error" => error}} -> raise "browser #{cmd} #{inspect(args)} failed: #{error}"
      {:error, reason} -> raise "browser driver died: #{inspect(reason)}"
    end
  end

  defp read(port, id) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case JSON.decode(line) do
          {:ok, %{"id" => ^id} = msg} -> {:ok, msg}
          _ -> read(port, id)
        end

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status}}
    after
      @call_timeout -> {:error, :timeout}
    end
  end
end

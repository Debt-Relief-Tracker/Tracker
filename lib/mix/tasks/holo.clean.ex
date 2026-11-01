defmodule Mix.Tasks.Holo.Clean do
  @shortdoc "Deletes Hologram's incremental build state so the next compile starts clean"

  @moduledoc """
  Hologram keeps incremental compiler state (call graph, chunk registry, ...)
  under `_build/<env>/lib/hologram/priv/` and its bundles in
  `priv/static/hologram/`. If that state goes stale -- e.g. after copying
  `_build` between checkouts or switching branches -- the browser can report
  `UndefinedFunctionError` for a function that exists in the source.

      mix holo.clean            # every _build/* env
      mix holo.clean dev test   # only these envs

  Then restart `mix holo` (the next compile rebuilds everything). Only
  generated files are removed.
  """

  use Mix.Task

  @state ~w(call_graph.bin compile_state.bin compile_inputs.bin module_info.plt
            chunk_registry.plt page_digest.plt tmp)

  @impl Mix.Task
  def run(args) do
    envs = if args == [], do: build_envs(), else: args

    for env <- envs, file <- @state do
      remove(Path.join(["_build", env, "lib", "hologram", "priv", file]))
    end

    remove(Path.join(["priv", "static", "hologram"]))
    Mix.shell().info("Hologram build state cleared. Restart `mix holo` to rebuild.")
  end

  defp build_envs do
    case File.ls("_build") do
      {:ok, entries} -> Enum.filter(entries, &File.dir?(Path.join("_build", &1)))
      _ -> []
    end
  end

  defp remove(path) do
    if File.exists?(path), do: File.rm_rf!(path)
  end
end

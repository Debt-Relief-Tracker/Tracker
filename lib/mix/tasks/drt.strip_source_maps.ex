defmodule Mix.Tasks.Drt.StripSourceMaps do
  @shortdoc "Deletes source maps and their //# sourceMappingURL comments from priv/static"

  @moduledoc """
  Production hardening: source maps expose the un-minified client source
  (including the Elixir-to-JS output of the Hologram bundles), so they must not
  be served. This deletes every `*.map` under `priv/static` and removes the
  trailing `//# sourceMappingURL=...` / `/*# sourceMappingURL=... */` comment
  from every `*.js` and `*.css` file there.

      mix drt.strip_source_maps [dir]      # default: priv/static

  It is part of `mix assets.deploy` (so the production Docker build runs it
  before `phx.digest`); dev and test builds never call it. Idempotent.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    root = List.first(args) || Path.join("priv", "static")
    {maps, stripped} = strip(root)
    Mix.shell().info("Source maps: deleted #{maps} file(s), stripped #{stripped} comment(s).")
  end

  @doc "Strips `root`; returns `{maps_deleted, files_with_comment_removed}`."
  @spec strip(Path.t()) :: {non_neg_integer(), non_neg_integer()}
  def strip(root) do
    files =
      Path.wildcard(Path.join(root, "**/*"), match_dot: true) |> Enum.filter(&File.regular?/1)

    maps = Enum.filter(files, &String.ends_with?(&1, ".map"))
    Enum.each(maps, &File.rm!/1)

    stripped =
      files
      |> Enum.filter(&(Path.extname(&1) in [".js", ".mjs", ".css"]))
      |> Enum.count(&strip_comment/1)

    {length(maps), stripped}
  end

  defp strip_comment(path) do
    content = File.read!(path)

    if String.contains?(content, "sourceMappingURL") do
      File.write!(path, Regex.replace(comment_regex(), content, ""))
      true
    else
      false
    end
  end

  defp comment_regex do
    ~r{(?:\n|\r\n)?[ \t]*(?://[#@] sourceMappingURL=[^\n]*|/\*[#@] sourceMappingURL=.*?\*/)[ \t]*(?=\n|\r\n|$)}s
  end
end

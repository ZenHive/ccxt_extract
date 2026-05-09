defmodule Mix.Tasks.CcxtExtract.UnlinkCorpus do
  @shortdoc "Remove symlinks created by `mix ccxt_extract.link_corpus`"

  @moduledoc """
  Removes the corpus symlinks created by `mix ccxt_extract.link_corpus`.

  Run this in a worktree before regenerating corpus locally
  (`mix ccxt_extract.update`, etc.) to avoid writing through symlinks back into
  the source checkout.

      mix ccxt_extract.unlink_corpus

  Only entries that are themselves symlinks are removed. Regular files,
  directories, and tracked files are never touched.
  """

  use Mix.Task

  @top_level ~w(ccxt ccxt_bundle.js output)

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    target_priv = Path.join(File.cwd!(), "priv")
    discoveries = Path.join(target_priv, "discoveries")

    candidates =
      Enum.map(@top_level, &Path.join(target_priv, &1)) ++ discovery_candidates(discoveries)

    removed =
      candidates
      |> Enum.filter(&symlink?/1)
      |> Enum.map(fn path ->
        File.rm!(path)
        path
      end)

    Mix.shell().info("Removed #{length(removed)} symlink(s) under #{target_priv}.")
    :ok
  end

  @spec discovery_candidates(String.t()) :: [String.t()]
  defp discovery_candidates(discoveries) do
    case File.ls(discoveries) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 == "class_hierarchy.json"))
        |> Enum.map(&Path.join(discoveries, &1))

      {:error, _} ->
        []
    end
  end

  @spec symlink?(String.t()) :: boolean()
  defp symlink?(path), do: match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
end

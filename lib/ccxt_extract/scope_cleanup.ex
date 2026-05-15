defmodule CcxtExtract.ScopeCleanup do
  @moduledoc """
  File-tree pruning and git-safety helpers for scoped extraction.

  * `prune_out_of_scope/3` — deletes per-exchange JSON files whose
    basename (sans `.json`) isn't in the in-scope MapSet. Only
    `.json` files are ever considered for deletion; every other
    extension (`.md`, `.txt`, `.exs`, dotfiles, etc.) is left alone
    even when recursing. Always preserves filenames starting with
    `_` (manifests, aggregate metadata) plus any explicit
    `:preserve` list. Optionally recurses into subdirectories for
    nested layouts like `priv/discoveries/describe/<id>.json`.

  * `git_status_clean?/2` — runs `git status --porcelain` against
    a path and reports dirty files. Used as a safety rail before
    destructive pipeline stages.
  """

  @type prune_opt :: {:preserve, [String.t()]} | {:recurse, boolean()}
  @type git_opt :: {:cd, Path.t()}

  @doc """
  Deletes JSON files in `dir` whose basename (without `.json`) is not
  in `in_scope`. Returns `{:ok, removed_paths}` with absolute paths
  sorted.

  Options:

    * `:preserve` — additional basenames to keep (e.g.
      `"exchange_v4.json"`). Default `[]`.
    * `:recurse` — descend into subdirectories. Subdirectory names
      themselves are never removed; only per-exchange files within.
      Default `false`.

  Files starting with `_` are always preserved.
  """
  @spec prune_out_of_scope(Path.t(), MapSet.t(String.t()), [prune_opt]) ::
          {:ok, [Path.t()]}
  def prune_out_of_scope(dir, in_scope, opts \\ []) do
    preserve = MapSet.new(Keyword.get(opts, :preserve, []))
    recurse = Keyword.get(opts, :recurse, false)
    removed = do_prune(dir, in_scope, preserve, recurse)
    {:ok, Enum.sort(removed)}
  end

  @doc """
  Runs `git status --porcelain` against `path` and returns:

    * `:ok` when the path has no uncommitted changes.
    * `{:error, dirty_lines}` when the path is dirty. Each entry is
      a trimmed porcelain line (e.g. `"M priv/output/binance.json"`).

  Raises `Mix.Error` if git exits non-zero (typically means `cd` is
  not inside a git repo).

  Option:

    * `:cd` — working directory for the git invocation. Defaults to
      the current process cwd.
  """
  @spec git_status_clean?(Path.t(), [git_opt]) :: :ok | {:error, [String.t()]}
  def git_status_clean?(path, opts \\ []) do
    cd = Keyword.get(opts, :cd, File.cwd!())

    case System.cmd("git", ["status", "--porcelain", "--", path],
           cd: cd,
           stderr_to_stdout: true
         ) do
      {"", 0} ->
        :ok

      {out, 0} ->
        {:error, out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)}

      {out, _code} ->
        raise Mix.Error, message: "git status failed in #{cd}: #{String.trim(out)}"
    end
  end

  defp do_prune(dir, in_scope, preserve, recurse) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.flat_map(entries, &handle_entry(Path.join(dir, &1), &1, in_scope, preserve, recurse))
      {:error, _} -> []
    end
  end

  defp handle_entry(path, basename, in_scope, preserve, recurse) do
    cond do
      File.dir?(path) and recurse -> do_prune(path, in_scope, preserve, recurse)
      File.dir?(path) -> []
      preserved?(basename, in_scope, preserve) -> []
      true -> remove(path)
    end
  end

  defp preserved?(basename, in_scope, preserve) do
    Path.extname(basename) != ".json" or
      String.starts_with?(basename, "_") or
      MapSet.member?(preserve, basename) or
      MapSet.member?(in_scope, Path.rootname(basename))
  end

  defp remove(path) do
    File.rm!(path)
    [path]
  end
end

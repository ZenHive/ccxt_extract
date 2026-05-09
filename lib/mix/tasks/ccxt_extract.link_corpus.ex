defmodule Mix.Tasks.CcxtExtract.LinkCorpus do
  @shortdoc "Symlink gitignored corpus from a source checkout into the current worktree"

  @moduledoc """
  Symlinks the gitignored extraction corpus from a source checkout (typically
  the main `ccxt_extract` clone) into the current working directory.

  Git worktrees share `.git` but each has an isolated working tree — gitignored
  derived state (`priv/output/`, `priv/discoveries/<not class_hierarchy.json>`,
  `priv/ccxt/`, `priv/ccxt_bundle.js`) only exists in whichever working tree last
  regenerated it. This task lets a fresh worktree pick up the existing corpus
  without rerunning `mix ccxt_extract.update`.

      # default source: ~/_DATA/code/ccxt_extract
      mix ccxt_extract.link_corpus

      # custom source
      mix ccxt_extract.link_corpus --from /path/to/source/checkout

  ## Symlinks created

      priv/ccxt           -> <source>/priv/ccxt
      priv/ccxt_bundle.js -> <source>/priv/ccxt_bundle.js
      priv/output         -> <source>/priv/output
      priv/discoveries/<each gitignored entry> -> <source>/priv/discoveries/<each>

  Tracked entries (`priv/discoveries/class_hierarchy.json`,
  `priv/ccxt_version.json`, `priv/schema/*`, `priv/overrides/*`,
  `priv/priority_tiers.json`, `priv/fixtures/*`, `priv/contract_test/*`) already
  exist in every worktree and are left alone. Existing non-symlink files at any
  target path are skipped with a warning rather than overwritten.

  ## ⚠️ Writeback hazard

  Directory symlinks are write-transparent: any task that regenerates corpus in
  this worktree (`mix ccxt_extract.update`, `mix ccxt_extract.pipeline`, the
  per-extractor mix tasks) will write through into the *source* checkout's
  corpus. Run `mix ccxt_extract.unlink_corpus` first to materialize a
  worktree-local corpus before regeneration.
  """

  use Mix.Task

  @default_source "~/_DATA/code/ccxt_extract"

  @top_level ~w(ccxt ccxt_bundle.js output)

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [from: :string])

    source = opts |> Keyword.get(:from, @default_source) |> Path.expand()
    target = File.cwd!()

    validate_source!(source, target)

    source_priv = Path.join(source, "priv")
    target_priv = Path.join(target, "priv")
    File.mkdir_p!(target_priv)

    {linked, skipped} =
      @top_level
      |> Enum.concat(discoveries_entries(source_priv))
      |> Enum.reduce({[], []}, fn rel, {linked, skipped} ->
        source_path = Path.join(source_priv, rel)
        target_path = Path.join(target_priv, rel)
        ensure_parent!(target_path)

        case attempt_link(source_path, target_path) do
          :linked -> {[rel | linked], skipped}
          :skipped -> {linked, [rel | skipped]}
          :missing -> {linked, skipped}
        end
      end)

    Mix.shell().info("""
    Linked #{length(linked)} entries from #{source_priv} into #{target_priv}.
    """)

    if skipped != [] do
      Mix.shell().info("Skipped (target exists, not a symlink):")
      Enum.each(Enum.sort(skipped), &Mix.shell().info("  priv/#{&1}"))
    end

    Mix.shell().info("Run `mix ccxt_extract.unlink_corpus` before regenerating corpus in this worktree.")

    :ok
  end

  @spec validate_source!(String.t(), String.t()) :: :ok
  defp validate_source!(source, target) do
    if same_directory?(source, target) do
      Mix.raise("Refusing to link a checkout to itself: source == target (#{source})")
    end

    if !File.dir?(Path.join(source, "priv")) do
      Mix.raise("Source priv/ directory does not exist: #{Path.join(source, "priv")}")
    end

    :ok
  end

  # macOS routes /tmp through a /private symlink, so two paths can string-differ
  # while referring to the same directory. Compare device + inode when both
  # exist; fall back to expanded-path equality.
  @spec same_directory?(String.t(), String.t()) :: boolean()
  defp same_directory?(a, b) do
    with {:ok, %File.Stat{inode: ia, major_device: da}} <- File.stat(a),
         {:ok, %File.Stat{inode: ib, major_device: db}} <- File.stat(b) do
      ia == ib and da == db
    else
      _ -> Path.expand(a) == Path.expand(b)
    end
  end

  @spec discoveries_entries(String.t()) :: [String.t()]
  defp discoveries_entries(source_priv) do
    discoveries = Path.join(source_priv, "discoveries")

    case File.ls(discoveries) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 == "class_hierarchy.json"))
        |> Enum.map(&Path.join("discoveries", &1))

      {:error, _} ->
        []
    end
  end

  @spec ensure_parent!(String.t()) :: :ok
  defp ensure_parent!(path) do
    path |> Path.dirname() |> File.mkdir_p!()
    :ok
  end

  @spec attempt_link(String.t(), String.t()) :: :linked | :skipped | :missing
  defp attempt_link(source_path, target_path) do
    cond do
      not lexists?(source_path) ->
        :missing

      symlink?(target_path) ->
        File.rm!(target_path)
        File.ln_s!(source_path, target_path)
        :linked

      lexists?(target_path) ->
        :skipped

      true ->
        File.ln_s!(source_path, target_path)
        :linked
    end
  end

  @spec lexists?(String.t()) :: boolean()
  defp lexists?(path), do: match?({:ok, _}, File.lstat(path))

  @spec symlink?(String.t()) :: boolean()
  defp symlink?(path), do: match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
end

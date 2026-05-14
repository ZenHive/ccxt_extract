defmodule Mix.Tasks.CcxtExtract.DeterminismCheck do
  @shortdoc "Verify extraction is byte-deterministic across consecutive runs"

  @moduledoc """
  Runs a list of extraction Mix tasks twice into two separate tmp
  directories (via `:priv_write_override`), then byte-diffs every
  `.json` file produced. Reports any divergence and exits non-zero
  when at least one file differs.

  Volatile timestamp keys (`extracted_at`, `generated_at`,
  `checked_at`, `validated_at`, `recorded_at`) are stripped before
  comparison so the gate passes while Pattern B writers still stamp
  wall-clock time (deferred Task 137). The harness re-encodes both
  sides through `Jason.OrderedObject` with sorted keys so map-iteration
  order can't masquerade as drift either — the resulting "byte equal"
  claim means the canonical-form bytes match, which is the strongest
  determinism statement we can make today.

  ## Usage

      mix ccxt_extract.determinism_check
      mix ccxt_extract.determinism_check --task ccxt_extract.exchanges
      mix ccxt_extract.determinism_check --task ccxt_extract.pipeline --scope-args="--tier1 --tier2"
      mix ccxt_extract.determinism_check --strip-keys extracted_at,generated_at,my_custom_key

  ## Options

    * `--task NAME` — Mix task to invoke (no `mix` prefix; e.g.
      `ccxt_extract.pipeline`). Repeatable; tasks run in the given
      order, fresh tmp dirs per pair. Defaults to
      `ccxt_extract.pipeline` when omitted — the cheapest invocation
      that exercises the per-exchange writer + manifest envelope.
    * `--scope-args STRING` — extra args appended verbatim to each
      task invocation. Must use `=` form (`--scope-args="--tier1 --tier2"`)
      since the value starts with `--` and `OptionParser` would otherwise
      treat it as a separate flag. Lets the same harness exercise scoped
      runs without baking flags into the task switches.
    * `--strip-keys k1,k2,...` — comma-separated volatile keys to
      drop at every depth before comparison. Replaces (not extends)
      the default set.
    * `--diff-dirs path1,path2,...` — relative-to-`priv/` directories
      to walk when collecting `.json` files. Defaults to
      `output,discoveries,fixtures/signing`. Files outside these roots
      are ignored.
    * `--context-bytes N` — width of the divergence preview printed
      per diverged file (default 80). Bytes are surfaced raw so
      embedded newlines / escapes are visible.

  ## Exit codes

  | code | meaning |
  |------|---------|
  | 0    | all `.json` files are byte-identical (post strip + canonical encode) |
  | 1    | at least one file diverges, OR read/decode error in either run, OR zero files were compared (task / `--diff-dirs` mismatch) |
  """

  use Mix.Task

  alias CcxtExtract.JsonDiff

  @switches [
    task: :keep,
    scope_args: :string,
    strip_keys: :string,
    diff_dirs: :string,
    context_bytes: :integer
  ]

  @default_tasks ["ccxt_extract.pipeline"]
  @default_diff_dirs ["output", "discoveries", "fixtures/signing"]

  @typep parsed :: %{
           tasks: [String.t()],
           scope_args: [String.t()],
           strip_keys: [String.t()],
           diff_dirs: [String.t()],
           context_bytes: integer()
         }

  @typep report :: %{
           total: non_neg_integer(),
           equal: non_neg_integer(),
           diverged: non_neg_integer(),
           errors: non_neg_integer(),
           missing: non_neg_integer(),
           details: [
             {:diff, String.t(), map()}
             | {:missing, String.t(), boolean()}
             | {:error, String.t(), term()}
           ]
         }

  @impl true
  @spec run([String.t()]) :: :ok
  def run(args) do
    parsed = parse_args!(args)
    Mix.shell().info("Running #{length(parsed.tasks)} task(s) twice into tmp dirs...")

    tmp_a = make_tmp_dir!("run_a")
    tmp_b = make_tmp_dir!("run_b")

    try do
      execute_check(parsed, tmp_a, tmp_b)
    after
      File.rm_rf!(tmp_a)
      File.rm_rf!(tmp_b)
    end
  end

  @spec parse_args!([String.t()]) :: parsed()
  defp parse_args!(args) do
    {opts, leftover, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      switches = Enum.map_join(invalid, ", ", fn {k, _} -> k end)
      Mix.raise("Unknown option(s): #{switches}")
    end

    if leftover != [] do
      Mix.raise("Unexpected argument(s): #{Enum.join(leftover, ", ")}")
    end

    %{
      tasks: tasks_from(opts),
      scope_args: parse_scope_args(opts[:scope_args]),
      strip_keys: parse_strip_keys(opts[:strip_keys]),
      diff_dirs: parse_diff_dirs(opts[:diff_dirs]),
      context_bytes: opts[:context_bytes] || 80
    }
  end

  @spec tasks_from(keyword()) :: [String.t()]
  defp tasks_from(opts) do
    case Keyword.get_values(opts, :task) do
      [] -> @default_tasks
      list -> list
    end
  end

  @spec execute_check(parsed(), Path.t(), Path.t()) :: :ok
  defp execute_check(parsed, tmp_a, tmp_b) do
    run_into!(tmp_a, parsed.tasks, parsed.scope_args)
    run_into!(tmp_b, parsed.tasks, parsed.scope_args)

    files_a = collect_json(tmp_a, parsed.diff_dirs)
    files_b = collect_json(tmp_b, parsed.diff_dirs)

    report =
      diff_all(files_a, files_b, tmp_a, tmp_b,
        strip_keys: parsed.strip_keys,
        context_bytes: parsed.context_bytes
      )

    print_report(report, parsed.context_bytes)

    # A run that compared zero files is a misconfiguration, not a pass:
    # the task wrote nothing under `--diff-dirs`. Fail loudly rather than
    # report a vacuous "0/0 equal".
    if report.total == 0 do
      Mix.raise(
        "Determinism check FAILED: 0 files compared — no `.json` files were " <>
          "produced under #{Enum.join(parsed.diff_dirs, ", ")}. Check --task and --diff-dirs."
      )
    end

    if report.diverged > 0 or report.errors > 0 or report.missing > 0 do
      Mix.raise("Determinism check FAILED: #{summary_line(report)}")
    end

    Mix.shell().info("Determinism check OK: #{summary_line(report)}")
  end

  @spec parse_scope_args(String.t() | nil) :: [String.t()]
  defp parse_scope_args(nil), do: []

  defp parse_scope_args(s) do
    String.split(s, ~r/\s+/, trim: true)
  end

  # TODO(Task 137): strip-keys is a workaround, not the fix. Pattern B
  # writers still stamp wall-clock time, so volatile keys must be dropped
  # before comparison. When Task 137 threads an `:extracted_at` opt through
  # those writers, this harness passes a frozen clock instead and the strip
  # set shrinks to genuinely-uncontrollable fields.
  @spec parse_strip_keys(String.t() | nil) :: [String.t()]
  defp parse_strip_keys(nil), do: JsonDiff.default_volatile_keys()

  defp parse_strip_keys(s) do
    s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  @spec parse_diff_dirs(String.t() | nil) :: [String.t()]
  defp parse_diff_dirs(nil), do: @default_diff_dirs

  defp parse_diff_dirs(s) do
    s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  @spec make_tmp_dir!(String.t()) :: Path.t()
  defp make_tmp_dir!(suffix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ccxt_determinism_#{suffix}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    path
  end

  # Sets :priv_write_override to `dir`, runs each task with `extra_args`
  # via `Mix.Task.rerun/2` (re-runs even after a prior invocation), then
  # restores the prior env.
  @spec run_into!(Path.t(), [String.t()], [String.t()]) :: :ok
  defp run_into!(dir, tasks, extra_args) do
    prior = Application.get_env(:ccxt_extract, :priv_write_override)
    Application.put_env(:ccxt_extract, :priv_write_override, dir)

    try do
      Enum.each(tasks, fn task ->
        Mix.shell().info("  [#{Path.basename(dir)}] mix #{task} #{Enum.join(extra_args, " ")}")
        Mix.Task.rerun(task, extra_args)
      end)
    after
      case prior do
        nil -> Application.delete_env(:ccxt_extract, :priv_write_override)
        val -> Application.put_env(:ccxt_extract, :priv_write_override, val)
      end
    end
  end

  @spec collect_json(Path.t(), [String.t()]) :: MapSet.t(String.t())
  defp collect_json(root, diff_dirs) do
    diff_dirs
    |> Enum.flat_map(fn rel ->
      base = Path.join(root, rel)

      if File.dir?(base) do
        base
        |> Path.join("**/*.json")
        |> Path.wildcard()
        |> Enum.map(&Path.relative_to(&1, root))
      else
        []
      end
    end)
    |> Enum.sort()
    |> MapSet.new()
  end

  @spec diff_all(MapSet.t(String.t()), MapSet.t(String.t()), Path.t(), Path.t(), keyword()) ::
          report()
  defp diff_all(files_a, files_b, root_a, root_b, opts) do
    all = files_a |> MapSet.union(files_b) |> MapSet.to_list() |> Enum.sort()

    all
    |> Enum.reduce(%{total: 0, equal: 0, diverged: 0, errors: 0, missing: 0, details: []}, fn
      rel, acc ->
        in_a = MapSet.member?(files_a, rel)
        in_b = MapSet.member?(files_b, rel)

        if in_a and in_b do
          classify_pair(Path.join(root_a, rel), Path.join(root_b, rel), rel, opts, acc)
        else
          %{
            acc
            | total: acc.total + 1,
              missing: acc.missing + 1,
              details: [{:missing, rel, in_a} | acc.details]
          }
        end
    end)
    |> finalize_details()
  end

  @spec classify_pair(Path.t(), Path.t(), String.t(), keyword(), report()) :: report()
  defp classify_pair(path_a, path_b, rel, opts, acc) do
    case JsonDiff.diff_files(path_a, path_b, opts) do
      :equal ->
        %{acc | total: acc.total + 1, equal: acc.equal + 1}

      {:diff, context} ->
        %{
          acc
          | total: acc.total + 1,
            diverged: acc.diverged + 1,
            details: [{:diff, rel, context} | acc.details]
        }

      {:error, reason} ->
        %{
          acc
          | total: acc.total + 1,
            errors: acc.errors + 1,
            details: [{:error, rel, reason} | acc.details]
        }
    end
  end

  @spec finalize_details(report()) :: report()
  defp finalize_details(report), do: %{report | details: Enum.reverse(report.details)}

  @spec summary_line(report()) :: String.t()
  defp summary_line(report) do
    "#{report.equal}/#{report.total} equal, #{report.diverged} diverged, #{report.missing} side-only, #{report.errors} errors"
  end

  @spec print_report(report(), integer()) :: :ok
  defp print_report(report, context_bytes) do
    Enum.each(report.details, fn
      {:diff, rel, %{byte: pos} = ctx} ->
        Mix.shell().error("  DIFF #{rel} @ byte #{pos}")
        Mix.shell().error("    a: #{format_context(ctx.a_context, context_bytes)}")
        Mix.shell().error("    b: #{format_context(ctx.b_context, context_bytes)}")

      {:missing, rel, in_a} ->
        side = if in_a, do: "only in run_a", else: "only in run_b"
        Mix.shell().error("  MISSING #{rel} (#{side})")

      {:error, rel, reason} ->
        Mix.shell().error("  ERROR #{rel}: #{inspect(reason)}")
    end)
  end

  @spec format_context(binary(), integer()) :: String.t()
  defp format_context(bytes, max_width) do
    bytes
    |> binary_slice(0, max_width)
    |> String.replace("\n", "\\n")
    |> String.replace("\t", "\\t")
  end
end

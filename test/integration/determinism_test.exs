defmodule CcxtExtract.DeterminismTest do
  @moduledoc """
  Phase 4 of Task 114 — verifies `CcxtExtract.AggregateWriter.merge/2`
  ordering semantics under scoped runs.

  **Invariant:** a scoped-merge *sequence* must equal a *single-shot*
  scoped run, byte-for-byte. Running `mix ccxt_extract.methods --tier1`
  then `--tier2` (each merging into the on-disk aggregate) must produce
  the same `methods_rest.json` / `methods_ws.json` as one
  `--tier1 --tier2` invocation.

  `ccxt_extract.methods` is the probe: it threads a `MapSet` scope
  through `Methods.write!/3` into `AggregateWriter.write!/3`, so the
  `--tier2` run actually exercises the `merge/2` reject-then-append
  path against the `--tier1` run's output (read back via `Paths.out/1`,
  which `:priv_write_override` redirects into the same tmp dir). This
  mirrors `mix ccxt_extract.update --tier1` followed by `--tier2` in
  production, minus the live QuickBEAM API calls that make the full
  `update` task untestable.

  Comparison goes through the Phase 1 harness
  (`CcxtExtract.JsonDiff.diff_files/3`): it strips volatile timestamp
  keys and re-encodes both sides through a sorted-key canonical form
  before the byte diff, so map-iteration order cannot masquerade as
  drift.

  Tagged `:extraction` — it re-parses the committed CCXT TypeScript
  corpus under `priv/ccxt/ts/src/`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias CcxtExtract.JsonDiff

  @moduletag :integration
  @moduletag :extraction
  @moduletag timeout: 240_000

  @probe_task "ccxt_extract.methods"
  @aggregates ["discoveries/methods_rest.json", "discoveries/methods_ws.json"]

  setup do
    # Mix.shell() is VM-global. Pin Mix.Shell.IO so a leaked
    # Mix.Shell.Process from another test file cannot intercept the
    # probe task's output (CLAUDE.md test conventions — the
    # setup_task_test.exs reference pattern).
    prior_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(prior_shell) end)
    :ok
  end

  describe "AggregateWriter.merge/2 under scoped sequences" do
    test "--tier1 then --tier2 equals a single --tier1 --tier2 run, byte-for-byte" do
      seq_dir = run_scoped([["--tier1"], ["--tier2"]])
      shot_dir = run_scoped([["--tier1", "--tier2"]])

      for rel <- @aggregates do
        seq_path = Path.join(seq_dir, rel)
        shot_path = Path.join(shot_dir, rel)

        assert File.exists?(seq_path), "scoped sequence did not write #{rel}"
        assert File.exists?(shot_path), "single-shot run did not write #{rel}"

        case JsonDiff.diff_files(seq_path, shot_path) do
          :equal ->
            :ok

          {:diff, ctx} ->
            flunk("""
            #{rel} diverged between scoped-sequence and single-shot runs at byte #{ctx.byte}.
              sequence: #{inspect(ctx.a_context)}
              single:   #{inspect(ctx.b_context)}
            """)

          {:error, reason} ->
            flunk("could not compare #{rel}: #{inspect(reason)}")
        end
      end
    end
  end

  # Runs each arg set through the probe task into a fresh tmp dir via
  # :priv_write_override, restoring the prior override afterward. The
  # tmp dir is registered for cleanup and returned for inspection.
  defp run_scoped(arg_sets) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ccxt_determinism_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    prior = Application.get_env(:ccxt_extract, :priv_write_override)
    Application.put_env(:ccxt_extract, :priv_write_override, dir)

    try do
      capture_io(fn ->
        Enum.each(arg_sets, &Mix.Task.rerun(@probe_task, &1))
      end)
    after
      case prior do
        nil -> Application.delete_env(:ccxt_extract, :priv_write_override)
        val -> Application.put_env(:ccxt_extract, :priv_write_override, val)
      end
    end

    dir
  end
end

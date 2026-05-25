defmodule Mix.Tasks.CcxtExtract.ValidateOverridesTest do
  @moduledoc """
  Drives the `ccxt_extract.validate_overrides` mix task end-to-end against
  controlled tmp corpora — option parsing, the `--overrides` / `--discoveries`
  / `--report` / `--exchange` flags, and the `--strict` non-zero exit.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.CcxtExtract.ValidateOverrides

  setup do
    # `Mix.shell/0` is VM-global; sibling task tests swap it to Mix.Shell.Process.
    # Pin to Mix.Shell.IO so `capture_io` sees the task's output. (Task 131 pattern.)
    prior_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)

    tmp = Path.join(System.tmp_dir!(), "vo_task_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "overrides"))
    File.mkdir_p!(Path.join(tmp, "discoveries"))

    on_exit(fn ->
      Mix.shell(prior_shell)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "argument parsing" do
    test "raises on an unknown option" do
      assert_raise Mix.Error, ~r/Unknown option/, fn ->
        ValidateOverrides.run(["--bogus"])
      end
    end

    test "raises on an unexpected positional argument" do
      assert_raise Mix.Error, ~r/Unexpected argument/, fn ->
        ValidateOverrides.run(["stray"])
      end
    end
  end

  describe "run/1" do
    test "clean corpus writes a report and does not raise", %{tmp: tmp} do
      write_overrides(tmp, "ex_clean", [clean_override()])
      report = Path.join(tmp, "report.json")

      out = capture_io(fn -> run_task(tmp, report, []) end)

      assert File.exists?(report)
      decoded = report |> File.read!() |> Jason.decode!()
      assert decoded["summary"]["exchanges"] == 1
      assert decoded["summary"]["mismatches"] == 0
      assert out =~ "Report:"
    end

    test "--exchange filters to the requested ids (honoring --overrides)", %{tmp: tmp} do
      write_overrides(tmp, "ex_one", [clean_override()])
      write_overrides(tmp, "ex_two", [clean_override()])
      report = Path.join(tmp, "report.json")

      capture_io(fn -> run_task(tmp, report, ["--exchange", "ex_one"]) end)

      decoded = report |> File.read!() |> Jason.decode!()
      assert decoded["summary"]["exchanges"] == 1
      assert [%{"exchange" => "ex_one"}] = decoded["exchanges"]
    end

    test "omitting --exchange checks every file in the --overrides dir", %{tmp: tmp} do
      write_overrides(tmp, "ex_one", [clean_override()])
      write_overrides(tmp, "ex_two", [clean_override()])
      report = Path.join(tmp, "report.json")

      capture_io(fn -> run_task(tmp, report, []) end)

      decoded = report |> File.read!() |> Jason.decode!()
      assert decoded["summary"]["exchanges"] == 2
    end
  end

  describe "--strict" do
    test "raises on a strict-class finding, report still written", %{tmp: tmp} do
      write_overrides(tmp, "ex_bad", [Map.put(clean_override(), "unverified", true)])
      report = Path.join(tmp, "report.json")

      assert_raise Mix.Error, ~r/strict-class findings/, fn ->
        capture_io(fn -> run_task(tmp, report, ["--strict"]) end)
      end

      assert File.exists?(report)
    end

    test "does not raise when only informational findings exist", %{tmp: tmp} do
      write_overrides(tmp, "ex_clean", [clean_override()])
      report = Path.join(tmp, "report.json")

      capture_io(fn -> run_task(tmp, report, ["--strict"]) end)

      decoded = report |> File.read!() |> Jason.decode!()
      assert decoded["summary"]["mismatches"] == 0
      assert decoded["summary"]["errors"] == 0
    end
  end

  # --- helpers ---

  defp run_task(tmp, report, extra) do
    ValidateOverrides.run(
      [
        "--overrides",
        Path.join(tmp, "overrides"),
        "--discoveries",
        Path.join(tmp, "discoveries"),
        "--report",
        report
      ] ++ extra
    )
  end

  # A url_templates-path override against an empty discovery corpus resolves to
  # informational `unverified` (no_url_templates_discovery) — clean under both
  # the default run and `--strict`.
  defp clean_override do
    %{"path" => "/runtime/url_templates", "value" => %{}, "reason" => "stub override"}
  end

  defp write_overrides(tmp, id, entries) do
    File.write!(
      Path.join([tmp, "overrides", "#{id}.json"]),
      Jason.encode!(%{"schema_version" => "1", "overrides" => entries})
    )
  end
end

defmodule CcxtExtract.DriftAuditTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.DriftAudit

  @current %{
    "exchange" => %{"id" => "synthex"},
    "_provenance" => %{
      "/auth/authenticated_sections" => "override",
      "/endpoints/public/foo" => "derived",
      "/raw/describe" => "raw",
      "/raw/new_thing" => "raw"
    },
    "auth" => %{"authenticated_sections" => ["private"]},
    "endpoints" => %{"public" => %{"foo" => 1}},
    "raw" => %{
      "describe" => %{"api" => %{}},
      "new_thing" => %{"x" => 42},
      "old_thing" => 7
    }
  }

  @baseline %{
    "exchange" => %{"id" => "synthex"},
    "_provenance" => %{
      "/auth/authenticated_sections" => "derived",
      "/endpoints/public/foo" => "derived",
      "/raw/describe" => "raw"
    },
    "auth" => %{"authenticated_sections" => ["public"]},
    "endpoints" => %{"public" => %{"foo" => 1}},
    "raw" => %{
      "describe" => %{"api" => %{}},
      "old_thing" => 7
    }
  }

  @overrides [
    %{"path" => "/structure/authenticated_sections", "value" => ["private"], "reason" => "test"}
  ]

  describe "classify_maps/4" do
    test "classifies stale_override when override path value differs from baseline" do
      findings = DriftAudit.classify_maps("synthex", @current, @baseline, @overrides)
      stale = Enum.filter(findings, &(&1.category == :stale_override))

      assert length(stale) == 1
      f = hd(stale)
      assert f.exchange == "synthex"
      assert f.path == "/auth/authenticated_sections"
      assert f.before == ["public"]
      assert f.after == ["private"]
      assert f.details["override_reason"] == "test"
    end

    test "does not classify stale_override for unrelated raw drift alone" do
      baseline = put_in(@baseline, ["auth", "authenticated_sections"], ["private"])
      current = put_in(@current, ["auth", "authenticated_sections"], ["private"])

      findings = DriftAudit.classify_maps("synthex", current, baseline, @overrides)
      stale = Enum.filter(findings, &(&1.category == :stale_override))

      assert stale == []
      assert Enum.any?(findings, &(&1.category == :new_raw))
    end

    test "classifies flipped_derived for a provenance=derived path whose value changed" do
      current = put_in(@current, ["endpoints", "public", "foo"], 99)
      findings = DriftAudit.classify_maps("synthex", current, @baseline, [])
      flipped = Enum.filter(findings, &(&1.category == :flipped_derived))

      assert length(flipped) == 1
      assert hd(flipped).path == "/endpoints/public/foo"
      assert hd(flipped).before == 1
      assert hd(flipped).after == 99
    end

    test "classifies new_raw for keys under raw that are absent from baseline raw" do
      findings = DriftAudit.classify_maps("synthex", @current, @baseline, [])
      new_raw = Enum.filter(findings, &(&1.category == :new_raw))
      ptrs = MapSet.new(new_raw, & &1.path)

      assert MapSet.member?(ptrs, "/raw/new_thing")
      refute MapSet.member?(ptrs, "/raw/old_thing")
    end
  end

  describe "run/1" do
    test "produces a well-shaped report with explicit baseline_dir" do
      tmp = Path.join(System.tmp_dir!(), "drift_audit_test_#{System.unique_integer([:positive])}")
      cur_dir = Path.join(tmp, "current")
      base_dir = Path.join(tmp, "baseline")
      File.mkdir_p!(cur_dir)
      File.mkdir_p!(base_dir)

      on_exit(fn -> File.rm_rf!(tmp) end)

      File.write!(Path.join(cur_dir, "_manifest.json"), Jason.encode!(%{"exchanges" => ["synthex"]}))
      File.write!(Path.join(cur_dir, "synthex.json"), Jason.encode!(@current))
      File.write!(Path.join(base_dir, "synthex.json"), Jason.encode!(@baseline))

      {:ok, report} =
        DriftAudit.run(
          output_dir: cur_dir,
          baseline_dir: base_dir,
          exchange_ids: ["synthex"]
        )

      assert report["summary"]["exchanges_compared"] == 1
      assert report["baseline"]["dir"] == base_dir
      assert Enum.any?(report["findings"], &(&1["category"] == "new_raw"))
    end

    test "missing baseline produces load_error entry but no crash" do
      {:ok, report} =
        DriftAudit.run(
          output_dir: System.tmp_dir!(),
          baseline_tag: "definitely-not-a-ref-#{:rand.uniform(999_999)}",
          exchange_ids: ["nope"]
        )

      [ex] = report["exchanges"]
      assert ex["baseline_load_error"] =~ "git_show_failed"
      assert ex["findings"] == []
    end
  end

  describe "write!/2" do
    test "writes pretty JSON report and creates parent directories" do
      tmp = Path.join(System.tmp_dir!(), "drift_audit_write_test_#{System.unique_integer([:positive])}")
      path = Path.join([tmp, "nested", "report.json"])

      on_exit(fn -> File.rm_rf!(tmp) end)

      report = %{"summary" => %{"total_findings" => 0}}
      assert :ok = DriftAudit.write!(report, path)
      assert {:ok, ^report} = Jason.decode(File.read!(path))
    end
  end
end

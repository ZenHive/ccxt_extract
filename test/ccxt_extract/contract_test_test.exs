defmodule CcxtExtract.ContractTestTest do
  use ExUnit.Case, async: true

  import CcxtExtract.Test.ExchangeFixtures, only: [schema_conformant: 1, schema_conformant: 2]

  alias CcxtExtract.ContractTest

  @base_observed %{error_code_fields_roots: ["response"]}

  defp clean_exchange, do: schema_conformant("good")

  describe "check_request_defaults_resolvable_reachable_from_unified/2" do
    defp literal_entry(value), do: %{"value" => value, "kind" => "literal", "reason" => nil}
    defp unresolved_entry(reason), do: %{"value" => nil, "kind" => "unresolved", "reason" => reason}

    test "no finding when literal method is a direct unified_endpoints key" do
      exchange = %{
        "id" => "goodex",
        "structure" => %{
          "unified_endpoints" => %{"fetchTime" => ["publicPostInfo"]},
          "request_defaults" => %{"fetchTime" => %{"type" => literal_entry("exchangeStatus")}}
        }
      }

      assert ContractTest.check_request_defaults_resolvable_reachable_from_unified(
               exchange,
               @base_observed
             ) == []
    end

    test "no finding when literal method appears as a value in unified_endpoints" do
      # NOTE(Task 110): In the current corpus, unified_endpoints VALUES are
      # always interface-method names (e.g. publicPostInfo) — never helper
      # method names (a corpus scan over priv/output/*.json finds 7306
      # interface-style values and 0 helper-style). This test locks the
      # predicate contract — that a method name appearing anywhere in a
      # unified_endpoints value list is considered reachable — for a future
      # world where transitive-helper analysis populates values with helper
      # names. It does NOT represent a shape that occurs in today's output.
      exchange = %{
        "id" => "synthex",
        "structure" => %{
          "unified_endpoints" => %{"fetchTime" => ["publicPostInfo", "fetchTimeHelper"]},
          "request_defaults" => %{
            "fetchTimeHelper" => %{"type" => literal_entry("exchangeStatus")}
          }
        }
      }

      assert ContractTest.check_request_defaults_resolvable_reachable_from_unified(
               exchange,
               @base_observed
             ) == []
    end

    test "finding when a literal method is neither a key nor a value in unified_endpoints" do
      exchange = %{
        "id" => "deadex",
        "structure" => %{
          "unified_endpoints" => %{"fetchTicker" => ["publicGetTicker"]},
          "request_defaults" => %{
            "fetchOrphan" => %{"type" => literal_entry("x")}
          }
        }
      }

      [finding] =
        ContractTest.check_request_defaults_resolvable_reachable_from_unified(
          exchange,
          @base_observed
        )

      assert finding.exchange == "deadex"
      assert finding.invariant == "request_defaults_resolvable_reachable_from_unified"
      assert finding.path == "structure.request_defaults.fetchOrphan"
      assert finding.message =~ "fetchOrphan"
    end

    test "unresolved-only method is ignored even when unreachable" do
      exchange = %{
        "id" => "unresolvedex",
        "structure" => %{
          "unified_endpoints" => %{"fetchTicker" => ["publicGetTicker"]},
          "request_defaults" => %{
            "fetchOrphan" => %{"type" => unresolved_entry("identifier_reference")}
          }
        }
      }

      assert ContractTest.check_request_defaults_resolvable_reachable_from_unified(
               exchange,
               @base_observed
             ) == []
    end

    test "no finding when request_defaults is absent or empty" do
      exchange = %{"id" => "emptyex", "structure" => %{"unified_endpoints" => %{}}}

      assert ContractTest.check_request_defaults_resolvable_reachable_from_unified(
               exchange,
               @base_observed
             ) == []
    end
  end

  describe "check_unified_endpoints_claimed_in_has/2" do
    test "no finding when every unified_endpoints key has matching has=true" do
      exchange = %{
        "id" => "goodex",
        "runtime" => %{"describe" => %{"has" => %{"fetchOHLCV" => true, "fetchTicker" => true}}},
        "structure" => %{"unified_endpoints" => %{"fetchOHLCV" => ["pubGetKlines"]}}
      }

      assert ContractTest.check_unified_endpoints_claimed_in_has(exchange, @base_observed) == []
    end

    test "finding when unified_endpoints declares a key that has does not claim true" do
      exchange = %{
        "id" => "badex",
        "runtime" => %{"describe" => %{"has" => %{"fetchOHLCV" => "__undefined"}}},
        "structure" => %{"unified_endpoints" => %{"fetchOHLCV" => ["pubGetKlines"]}}
      }

      [finding] = ContractTest.check_unified_endpoints_claimed_in_has(exchange, @base_observed)
      assert finding.exchange == "badex"
      assert finding.invariant == "unified_endpoints_claimed_in_has"
      assert finding.path == "structure.unified_endpoints.fetchOHLCV"
      assert finding.message =~ "fetchOHLCV"
    end

    test "no finding when parents are missing" do
      exchange = %{"id" => "emptyex"}
      assert ContractTest.check_unified_endpoints_claimed_in_has(exchange, @base_observed) == []
    end
  end

  describe "check_authenticated_sections_reachable_in_api/2" do
    test "no finding when every section is a top-level api key" do
      exchange = %{
        "id" => "flatex",
        "runtime" => %{"describe" => %{"api" => %{"private" => %{}, "public" => %{}}}},
        "structure" => %{"authenticated_sections" => ["private"]}
      }

      assert ContractTest.check_authenticated_sections_reachable_in_api(exchange, @base_observed) ==
               []
    end

    test "no finding when section is nested under another api grouping" do
      exchange = %{
        "id" => "nestedex",
        "runtime" => %{
          "describe" => %{"api" => %{"v2" => %{"private" => %{}}, "v3" => %{"private" => %{}}}}
        },
        "structure" => %{"authenticated_sections" => ["private"]}
      }

      assert ContractTest.check_authenticated_sections_reachable_in_api(exchange, @base_observed) ==
               []
    end

    test "finding when section is nowhere in the api tree" do
      exchange = %{
        "id" => "missingex",
        "runtime" => %{"describe" => %{"api" => %{"public" => %{}}}},
        "structure" => %{"authenticated_sections" => ["wapi"]}
      }

      [finding] =
        ContractTest.check_authenticated_sections_reachable_in_api(exchange, @base_observed)

      assert finding.exchange == "missingex"
      assert finding.invariant == "authenticated_sections_reachable_in_api"
      assert finding.path == "structure.authenticated_sections[0]"
      assert finding.message =~ "wapi"
    end

    test "no finding when parents are missing" do
      exchange = %{"id" => "emptyex"}

      assert ContractTest.check_authenticated_sections_reachable_in_api(exchange, @base_observed) ==
               []
    end
  end

  describe "check_error_code_fields_root/2" do
    test "no finding when every root is in the baseline set" do
      exchange = %{
        "id" => "ok",
        "structure" => %{
          "handle_errors" => %{
            "error_code_fields" => [
              %{"object" => "response", "object_path" => nil, "field" => "msg"},
              %{"object" => "error", "object_path" => ["error", "code"], "field" => "msg"}
            ]
          }
        }
      }

      observed = %{error_code_fields_roots: MapSet.new(["response", "error"])}
      assert ContractTest.check_error_code_fields_root(exchange, observed) == []
    end

    test "finding points at object when root comes from object fallback" do
      exchange = %{
        "id" => "drift",
        "structure" => %{
          "handle_errors" => %{
            "error_code_fields" => [
              %{"object" => "unusualRoot", "object_path" => nil, "field" => "msg"}
            ]
          }
        }
      }

      observed = %{error_code_fields_roots: ["response"]}
      [finding] = ContractTest.check_error_code_fields_root(exchange, observed)
      assert finding.exchange == "drift"
      assert finding.invariant == "error_code_fields_root_in_observed_set"
      assert finding.path == "structure.handle_errors.error_code_fields[0].object"
      assert finding.message =~ "unusualRoot"
    end

    test "finding points at object_path when root comes from object_path" do
      exchange = %{
        "id" => "pathdrift",
        "structure" => %{
          "handle_errors" => %{
            "error_code_fields" => [
              %{"object" => "response", "object_path" => ["unexpected", "code"], "field" => "msg"}
            ]
          }
        }
      }

      observed = %{error_code_fields_roots: ["response"]}
      [finding] = ContractTest.check_error_code_fields_root(exchange, observed)
      assert finding.exchange == "pathdrift"
      assert finding.path == "structure.handle_errors.error_code_fields[0].object_path"
      assert finding.message =~ "unexpected"
    end

    test "no finding when parents are missing" do
      exchange = %{"id" => "emptyex"}
      assert ContractTest.check_error_code_fields_root(exchange, @base_observed) == []
    end
  end

  describe "check_override_paths_present_in_output/2" do
    alias CcxtExtract.OverrideRegistry

    test "no findings when exchange has no override file" do
      exchange = %{"exchange" => %{"id" => "__no_override_#{System.unique_integer([:positive])}__"}}
      assert ContractTest.check_override_paths_present_in_output(exchange, @base_observed) == []
    end

    test "no findings when every override value appears at its path in output" do
      # Construct an exchange map via apply_all/2 using the real production
      # override file — guarantees every entry's value is observable at its path.
      seed = %{"exchange" => %{"id" => "hyperliquid"}, "structure" => %{}}
      overrides = OverrideRegistry.load("hyperliquid")
      exchange = OverrideRegistry.apply_all(seed, overrides)

      assert ContractTest.check_override_paths_present_in_output(exchange, @base_observed) == []
    end

    test "finding when exchange output drifts from override value" do
      # hyperliquid's authenticated_sections override — here the exchange map
      # carries a drifted value that does not match the override.
      exchange = %{
        "exchange" => %{"id" => "hyperliquid"},
        "structure" => %{"authenticated_sections" => ["drifted"]}
      }

      [finding] = ContractTest.check_override_paths_present_in_output(exchange, @base_observed)

      assert finding.exchange == "hyperliquid"
      assert finding.invariant == "override_paths_present_in_output"
      assert finding.path == "/structure/authenticated_sections"
      assert finding.message =~ "drifted"
    end
  end

  describe "check_provenance_covers_schema/2" do
    test "no findings when every declared pointer resolves and tags match" do
      assert ContractTest.check_provenance_covers_schema(clean_exchange(), @base_observed) == []
    end

    test "uncovered_section finding when pipeline emits a section Provenance does not declare" do
      exchange = put_in(clean_exchange(), ["structure", "new_undeclared_section"], %{})

      [finding] = ContractTest.check_provenance_covers_schema(exchange, @base_observed)
      assert finding.invariant == "provenance_covers_schema"
      assert finding.path == "/structure/new_undeclared_section"
      assert finding.message =~ "not declared in Provenance"
    end

    test "orphan_declaration finding when a declared pointer does not resolve in output" do
      # Drop /structure/pagination entirely from the exchange
      exchange = update_in(clean_exchange(), ["structure"], &Map.delete(&1, "pagination"))

      findings = ContractTest.check_provenance_covers_schema(exchange, @base_observed)
      paths = Enum.map(findings, & &1.path)
      assert "/structure/pagination" in paths
      assert Enum.all?(findings, &(&1.invariant == "provenance_covers_schema"))
    end

    test "tag_mismatch finding when _provenance tag disagrees with predicted split" do
      # /runtime/describe is declared raw; flip to "derived" in the map
      exchange = put_in(clean_exchange(), ["_provenance", "/runtime/describe"], "derived")

      findings = ContractTest.check_provenance_covers_schema(exchange, @base_observed)
      mismatch = Enum.find(findings, &(&1.path == "/runtime/describe"))
      assert mismatch
      assert mismatch.invariant == "provenance_covers_schema"
      assert mismatch.message =~ "expected \"raw\""
      assert mismatch.message =~ "got \"derived\""
    end

    test "override tag is always accepted regardless of predicted split" do
      # Flip a raw pointer to "override" — should produce NO tag_mismatch
      exchange = put_in(clean_exchange(), ["_provenance", "/runtime/describe"], "override")

      findings = ContractTest.check_provenance_covers_schema(exchange, @base_observed)

      refute Enum.any?(
               findings,
               &(&1.path == "/runtime/describe" and &1.invariant == "provenance_covers_schema")
             )
    end

    test "nil parent is vacuously resolved (Honesty Rule) — no orphan findings for its subkeys" do
      # /structure/handle_errors = nil legitimately means "extractor produced
      # nothing"; the declared subkeys should NOT be flagged as orphans.
      exchange = put_in(clean_exchange(), ["structure", "handle_errors"], nil)

      findings = ContractTest.check_provenance_covers_schema(exchange, @base_observed)

      refute Enum.any?(findings, &String.starts_with?(&1.path, "/structure/handle_errors"))
    end

    test "override path tag suppresses uncovered_section even for undeclared pointers" do
      # Undeclared section + an override tag at that path → no uncovered finding
      exchange =
        clean_exchange()
        |> put_in(["structure", "custom_override"], %{})
        |> put_in(["_provenance", "/structure/custom_override"], "override")

      findings = ContractTest.check_provenance_covers_schema(exchange, @base_observed)
      refute Enum.any?(findings, &(&1.path == "/structure/custom_override"))
    end
  end

  describe "check_paths_rw_split/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "ccxt_paths_rw_split_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "returns no findings for real lib/ (baseline green after Task 111)" do
      assert ContractTest.check_paths_rw_split() == []
    end

    test "flags a same-file read-helper → File.write! flow in a planted fixture", %{tmp: tmp} do
      leak_file = Path.join(tmp, "leak.ex")

      File.write!(leak_file, """
      defmodule Fixture.Leak do
        def run do
          path = CcxtExtract.Paths.priv("leak.json")
          File.write!(path, "x")
        end
      end
      """)

      findings = ContractTest.check_paths_rw_split(glob: Path.join(tmp, "**/*.ex"))

      assert [finding] = findings
      assert finding.exchange == "_corpus"
      assert finding.invariant == "paths_rw_split"
      assert finding.path =~ "leak.ex:"
      assert finding.message =~ "CcxtExtract.Paths.priv"
      assert finding.message =~ "File.write!"
    end

    test "does not flag cross-module flow (same-file filter)", %{tmp: tmp} do
      File.write!(Path.join(tmp, "reader.ex"), """
      defmodule Fixture.Reader do
        def run do
          fixtures = CcxtExtract.Paths.priv("fixtures")
          Fixture.Writer.write(fixtures, "report.json")
        end
      end
      """)

      File.write!(Path.join(tmp, "writer.ex"), """
      defmodule Fixture.Writer do
        def write(_unused, path) do
          File.write!(path, "x")
        end
      end
      """)

      assert ContractTest.check_paths_rw_split(glob: Path.join(tmp, "**/*.ex")) == []
    end
  end

  describe "run_all/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "ccxt_contract_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "loads JSON, runs invariants, returns deterministic report", %{tmp: tmp} do
      good =
        "good"
        |> schema_conformant(
          describe: %{
            "has" => %{"fetchOHLCV" => true},
            "api" => %{"private" => %{}, "public" => %{}}
          },
          unified_endpoints: %{"fetchOHLCV" => ["x"]},
          authenticated_sections: ["private"]
        )
        |> put_in(
          ["structure", "handle_errors", "error_code_fields"],
          [%{"object" => "response", "object_path" => nil, "field" => "msg"}]
        )

      bad =
        schema_conformant("bad",
          describe: %{"has" => %{"fetchOHLCV" => "__undefined"}, "api" => %{"public" => %{}}},
          unified_endpoints: %{"fetchOHLCV" => ["x"]},
          authenticated_sections: ["wapi"]
        )

      File.write!(Path.join(tmp, "good.json"), Jason.encode!(good))
      File.write!(Path.join(tmp, "bad.json"), Jason.encode!(bad))
      File.write!(Path.join(tmp, "_manifest.json"), "{}")

      {:ok, report} = ContractTest.run_all(output_dir: tmp, baseline_roots: ["response"])

      assert report["summary"]["exchanges_checked"] == 2

      assert report["summary"]["invariants_run"] ==
               length(ContractTest.invariants()) + length(ContractTest.corpus_invariants())

      assert report["summary"]["findings_by_invariant"]["unified_endpoints_claimed_in_has"] == 1

      assert report["summary"]["findings_by_invariant"][
               "authenticated_sections_reachable_in_api"
             ] == 1

      # Fixtures are schema-conformant, so only the two intended
      # invariants fire — no reject filter needed.
      assert report["summary"]["total_findings"] == 2

      # Findings sorted by {exchange, invariant, path}
      [f1, f2] = report["findings"]
      assert f1["exchange"] == "bad"
      assert f2["exchange"] == "bad"
      assert f1["invariant"] <= f2["invariant"]

      # Baseline roots come from the committed safelist, not the corpus
      assert report["baseline"]["error_code_fields_roots"] == ["response"]
    end

    test "skips exchange_v2.json (schema copy) alongside per-exchange JSON", %{tmp: tmp} do
      File.write!(Path.join(tmp, "real.json"), Jason.encode!(%{"id" => "real"}))
      File.write!(Path.join(tmp, "exchange_v2.json"), Jason.encode!(%{"$schema" => "x"}))
      File.write!(Path.join(tmp, "_manifest.json"), "{}")

      {:ok, report} = ContractTest.run_all(output_dir: tmp, baseline_roots: [])

      assert report["summary"]["exchanges_checked"] == 1
    end

    test "raises when baseline file is missing and no inline roots given", %{tmp: tmp} do
      File.write!(Path.join(tmp, "x.json"), Jason.encode!(%{"id" => "x"}))

      assert_raise RuntimeError, ~r/baseline missing/, fn ->
        ContractTest.run_all(output_dir: tmp, baseline_path: Path.join(tmp, "missing.json"))
      end
    end

    test "writes report via write!/2", %{tmp: tmp} do
      File.write!(Path.join(tmp, "x.json"), Jason.encode!(%{"id" => "x"}))
      {:ok, report} = ContractTest.run_all(output_dir: tmp, baseline_roots: [])
      out = Path.join(tmp, "report.json")
      assert :ok = ContractTest.write!(report, out)
      assert out |> File.read!() |> Jason.decode!() == report
    end

    test ~s|tier_scope defaults to "all" when opt not passed|, %{tmp: tmp} do
      File.write!(Path.join(tmp, "x.json"), Jason.encode!(%{"id" => "x"}))
      {:ok, report} = ContractTest.run_all(output_dir: tmp, baseline_roots: [])
      assert report["tier_scope"] == "all"
    end

    test "tier_scope is stamped verbatim from opts", %{tmp: tmp} do
      File.write!(Path.join(tmp, "x.json"), Jason.encode!(%{"id" => "x"}))

      {:ok, report} =
        ContractTest.run_all(output_dir: tmp, baseline_roots: [], tier_scope: ["tier1", "tier2"])

      assert report["tier_scope"] == ["tier1", "tier2"]
    end
  end
end

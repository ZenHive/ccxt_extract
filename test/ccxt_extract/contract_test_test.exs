defmodule CcxtExtract.ContractTestTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.ContractTest

  @base_observed %{error_code_fields_roots: ["response"]}

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

  describe "run_all/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "ccxt_contract_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "loads JSON, runs invariants, returns deterministic report", %{tmp: tmp} do
      good = %{
        "id" => "good",
        "runtime" => %{
          "describe" => %{
            "has" => %{"fetchOHLCV" => true},
            "api" => %{"private" => %{}, "public" => %{}}
          }
        },
        "structure" => %{
          "unified_endpoints" => %{"fetchOHLCV" => ["x"]},
          "authenticated_sections" => ["private"],
          "handle_errors" => %{
            "error_code_fields" => [
              %{"object" => "response", "object_path" => nil, "field" => "msg"}
            ]
          }
        }
      }

      bad = %{
        "id" => "bad",
        "runtime" => %{
          "describe" => %{
            "has" => %{"fetchOHLCV" => "__undefined"},
            "api" => %{"public" => %{}}
          }
        },
        "structure" => %{
          "unified_endpoints" => %{"fetchOHLCV" => ["x"]},
          "authenticated_sections" => ["wapi"],
          "handle_errors" => %{"error_code_fields" => []}
        }
      }

      File.write!(Path.join(tmp, "good.json"), Jason.encode!(good))
      File.write!(Path.join(tmp, "bad.json"), Jason.encode!(bad))
      File.write!(Path.join(tmp, "_manifest.json"), "{}")

      {:ok, report} = ContractTest.run_all(output_dir: tmp, baseline_roots: ["response"])

      assert report["summary"]["exchanges_checked"] == 2
      assert report["summary"]["invariants_run"] == 3
      assert report["summary"]["total_findings"] == 2
      assert report["summary"]["findings_by_invariant"]["unified_endpoints_claimed_in_has"] == 1

      assert report["summary"]["findings_by_invariant"][
               "authenticated_sections_reachable_in_api"
             ] == 1

      # Findings sorted by {exchange, invariant, path}
      [f1, f2] = report["findings"]
      assert f1["exchange"] == "bad"
      assert f2["exchange"] == "bad"
      assert f1["invariant"] <= f2["invariant"]

      # Baseline roots come from the committed safelist, not the corpus
      assert report["baseline"]["error_code_fields_roots"] == ["response"]
    end

    test "skips exchange_v1.json (schema copy) alongside per-exchange JSON", %{tmp: tmp} do
      File.write!(Path.join(tmp, "real.json"), Jason.encode!(%{"id" => "real"}))
      File.write!(Path.join(tmp, "exchange_v1.json"), Jason.encode!(%{"$schema" => "x"}))
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
  end
end

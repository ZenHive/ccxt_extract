defmodule CcxtExtract.ContractTestTest do
  # async: false because `check_paths_rw_split/1` and `run_all/1` call
  # `Reach.Project.from_glob/1`, which delegates to `Task.async_stream` with
  # Elixir's hardcoded 5s default timeout (Reach 2.2 doesn't thread a
  # `:timeout` option through `parse_files`/`build_module_sdgs`). Under the
  # async test pool's CPU contention, even small fixture globs trip that 5s
  # ceiling — see Task 131 (originally hypothesized as suite-order pollution
  # but actually pool-contention-vs-timeout). Until upstream Reach exposes
  # a timeout knob, serializing this file's 45 tests costs ~2s vs flaky CI.
  use ExUnit.Case, async: false

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

  describe "check_sign_recipe_honesty_valid/2 (Task 69)" do
    alias CcxtExtract.SignRecipe

    defp exchange_with_recipe(id, recipe_map) do
      clean_exchange()
      |> put_in(["exchange", "id"], id)
      |> put_in(["structure", "sign_recipe"], recipe_map)
    end

    defp populated_recipe do
      SignRecipe.null_recipe()
      |> Map.put("crypto_op", %{"algo" => "hmac_sha256"})
      |> Map.put("canonical_string", %{})
      |> Map.put("signature_placement", %{"location" => "header", "key" => "X-SIGN"})
      |> Map.put("auth_headers", [])
      |> Map.put("nonce", %{"source" => "timestamp_ms", "format" => "integer"})
      |> Map.put("timestamp", %{"source" => "timestamp_ms", "format" => "integer"})
      |> Map.put("pre_sign_transforms", [])
    end

    test "empty sign_recipe map emits no findings" do
      exchange = exchange_with_recipe("empty_recipe", %{})
      assert ContractTest.check_sign_recipe_honesty_valid(exchange, @base_observed) == []
    end

    test "scaffold null_recipe (all-null + not_yet_derived tag) emits no findings" do
      # Biconditional holds: tag is populated (non-nil), and all seven fields
      # are null, so the "iff" clause is satisfied on both sides.
      recipe = %{"private" => SignRecipe.null_recipe()}
      exchange = exchange_with_recipe("scaffold", recipe)
      assert ContractTest.check_sign_recipe_honesty_valid(exchange, @base_observed) == []
    end

    test "fully-populated record with unresolved_reason: nil emits no findings (happy path)" do
      recipe = %{"private" => Map.put(populated_recipe(), "unresolved_reason", nil)}
      exchange = exchange_with_recipe("fully_populated", recipe)
      assert ContractTest.check_sign_recipe_honesty_valid(exchange, @base_observed) == []
    end

    test "fully-populated record with non-null tag emits a right→left violation finding" do
      # Derive's write-side should have flipped this to nil. Escape =>
      # means something bypassed Derive (e.g. override chain) — flag it.
      recipe = %{"private" => Map.put(populated_recipe(), "unresolved_reason", "not_yet_derived")}
      exchange = exchange_with_recipe("stale_tag", recipe)

      [finding] = ContractTest.check_sign_recipe_honesty_valid(exchange, @base_observed)

      assert finding.exchange == "stale_tag"
      assert finding.invariant == "sign_recipe_honesty_valid"
      assert finding.path == "structure.sign_recipe.private"
      assert finding.message =~ "not_yet_derived"
      assert finding.message =~ "all seven derivation fields are populated"
    end

    test "partial record with unresolved_reason: nil emits a left→right violation finding" do
      recipe = %{
        "private" =>
          populated_recipe()
          |> Map.put("pre_sign_transforms", nil)
          |> Map.put("unresolved_reason", nil)
      }

      exchange = exchange_with_recipe("lying_tag", recipe)

      [finding] = ContractTest.check_sign_recipe_honesty_valid(exchange, @base_observed)

      assert finding.exchange == "lying_tag"
      assert finding.invariant == "sign_recipe_honesty_valid"
      assert finding.path == "structure.sign_recipe.private"
      assert finding.message =~ "unresolved_reason is null"
      assert finding.message =~ ~s("pre_sign_transforms")
    end

    test "left→right finding names every null field, not just one" do
      recipe = %{
        "private" =>
          populated_recipe()
          |> Map.put("auth_headers", nil)
          |> Map.put("nonce", nil)
          |> Map.put("pre_sign_transforms", nil)
          |> Map.put("unresolved_reason", nil)
      }

      exchange = exchange_with_recipe("multi_null", recipe)

      [finding] = ContractTest.check_sign_recipe_honesty_valid(exchange, @base_observed)

      assert finding.message =~ "auth_headers"
      assert finding.message =~ "nonce"
      assert finding.message =~ "pre_sign_transforms"
    end

    test "terminal ambiguous_ast tag on partial record emits no findings" do
      # ambiguous_ast means crypto_op is nil by construction — biconditional
      # holds because the tag is non-null AND at least one field is null.
      recipe = %{
        "private" =>
          populated_recipe()
          |> Map.put("crypto_op", nil)
          |> Map.put("unresolved_reason", "ambiguous_ast")
      }

      exchange = exchange_with_recipe("ambiguous", recipe)
      assert ContractTest.check_sign_recipe_honesty_valid(exchange, @base_observed) == []
    end

    test "terminal no_sign_method tag with all-null fields emits no findings" do
      recipe = %{
        "private" => Map.put(SignRecipe.null_recipe(), "unresolved_reason", "no_sign_method")
      }

      exchange = exchange_with_recipe("no_sign", recipe)
      assert ContractTest.check_sign_recipe_honesty_valid(exchange, @base_observed) == []
    end

    test "terminal custom_signing_family tag with all-null fields emits no findings" do
      recipe = %{
        "private" => Map.put(SignRecipe.null_recipe(), "unresolved_reason", "custom_signing_family")
      }

      exchange = exchange_with_recipe("custom_family", recipe)
      assert ContractTest.check_sign_recipe_honesty_valid(exchange, @base_observed) == []
    end

    test "multiple sections reported deterministically (sorted by section name)" do
      recipe = %{
        "zprivate" => Map.put(populated_recipe(), "unresolved_reason", "not_yet_derived"),
        "aprivate" => Map.put(populated_recipe(), "unresolved_reason", "not_yet_derived")
      }

      exchange = exchange_with_recipe("multi_section", recipe)
      findings = ContractTest.check_sign_recipe_honesty_valid(exchange, @base_observed)

      assert length(findings) == 2
      # Alphabetical order means aprivate comes before zprivate.
      assert Enum.at(findings, 0).path == "structure.sign_recipe.aprivate"
      assert Enum.at(findings, 1).path == "structure.sign_recipe.zprivate"
    end
  end

  describe "check_error_class_hierarchy_shape_valid/2" do
    defp exchange_with_hierarchy(id, hierarchy) do
      %{
        "exchange" => %{"id" => id},
        "structure" => %{"error_class_hierarchy" => hierarchy}
      }
    end

    defp valid_hierarchy do
      %{
        "tree" => %{"BaseError" => %{"ExchangeError" => %{"AuthenticationError" => %{}}}},
        "flat_parents" => %{
          "BaseError" => nil,
          "ExchangeError" => "BaseError",
          "AuthenticationError" => "ExchangeError"
        },
        "ancestors" => %{
          "BaseError" => [],
          "ExchangeError" => ["BaseError"],
          "AuthenticationError" => ["ExchangeError", "BaseError"]
        }
      }
    end

    test "no findings on a valid hierarchy" do
      exchange = exchange_with_hierarchy("good", valid_hierarchy())
      assert ContractTest.check_error_class_hierarchy_shape_valid(exchange, @base_observed) == []
    end

    test "no findings when error_class_hierarchy is null (missing-data signal upstream)" do
      exchange = exchange_with_hierarchy("nullex", nil)
      assert ContractTest.check_error_class_hierarchy_shape_valid(exchange, @base_observed) == []
    end

    test "flags missing required keys" do
      exchange = exchange_with_hierarchy("bad", %{"tree" => %{}})
      assert [finding] = ContractTest.check_error_class_hierarchy_shape_valid(exchange, @base_observed)
      assert finding.invariant == "error_class_hierarchy_shape_valid"
      assert finding.message =~ "missing required keys"
      assert finding.message =~ "flat_parents"
      assert finding.message =~ "ancestors"
    end

    test "flags non-map tree" do
      bad = %{valid_hierarchy() | "tree" => "not a map"}
      exchange = exchange_with_hierarchy("bad", bad)
      assert [finding] = ContractTest.check_error_class_hierarchy_shape_valid(exchange, @base_observed)
      assert finding.message =~ "tree must be a map"
    end

    test "flags missing root (cycle / no class with nil parent)" do
      cyclic = %{
        "tree" => %{},
        "flat_parents" => %{"A" => "B", "B" => "A"},
        "ancestors" => %{"A" => ["B", "A"], "B" => ["A", "B"]}
      }

      exchange = exchange_with_hierarchy("bad", cyclic)
      findings = ContractTest.check_error_class_hierarchy_shape_valid(exchange, @base_observed)

      assert Enum.any?(findings, &String.contains?(&1.message, "no root class found"))
    end

    test "flags wrong root name" do
      bad =
        Map.merge(valid_hierarchy(), %{
          "flat_parents" => %{"OtherRoot" => nil, "Child" => "OtherRoot"},
          "ancestors" => %{"OtherRoot" => [], "Child" => ["OtherRoot"]}
        })

      exchange = exchange_with_hierarchy("bad", bad)
      findings = ContractTest.check_error_class_hierarchy_shape_valid(exchange, @base_observed)

      assert Enum.any?(findings, &String.contains?(&1.message, "expected \"BaseError\""))
    end

    test "flags multiple roots" do
      bad =
        Map.merge(valid_hierarchy(), %{
          "flat_parents" => %{"BaseError" => nil, "OtherRoot" => nil, "Child" => "BaseError"},
          "ancestors" => %{"BaseError" => [], "OtherRoot" => [], "Child" => ["BaseError"]}
        })

      exchange = exchange_with_hierarchy("bad", bad)
      findings = ContractTest.check_error_class_hierarchy_shape_valid(exchange, @base_observed)

      assert Enum.any?(findings, &String.contains?(&1.message, "expected exactly one root"))
    end

    test "flags ancestors that disagree with flat_parents walk" do
      bad =
        Map.put(valid_hierarchy(), "ancestors", %{
          "BaseError" => [],
          "ExchangeError" => ["BaseError"],
          "AuthenticationError" => ["BaseError"]
        })

      exchange = exchange_with_hierarchy("bad", bad)
      findings = ContractTest.check_error_class_hierarchy_shape_valid(exchange, @base_observed)

      assert Enum.any?(findings, &String.contains?(&1.message, "disagrees with flat_parents walk"))
    end

    test "flags coverage gap (flat_parents has key absent from ancestors)" do
      bad =
        Map.put(valid_hierarchy(), "ancestors", %{"BaseError" => [], "ExchangeError" => ["BaseError"]})

      exchange = exchange_with_hierarchy("bad", bad)
      findings = ContractTest.check_error_class_hierarchy_shape_valid(exchange, @base_observed)

      assert Enum.any?(findings, &String.contains?(&1.message, "missing from ancestors"))
    end
  end

  describe "check_error_classes_covered_by_hierarchy/2" do
    defp exchange_with_handle_errors_and_hierarchy(id, handle_errors, hierarchy) do
      %{
        "exchange" => %{"id" => id},
        "structure" => %{
          "handle_errors" => handle_errors,
          "error_class_hierarchy" => hierarchy
        }
      }
    end

    test "no findings when every referenced class is in flat_parents" do
      hierarchy = %{
        "tree" => %{},
        "flat_parents" => %{
          "BaseError" => nil,
          "ExchangeError" => "BaseError",
          "RateLimitExceeded" => "BaseError"
        },
        "ancestors" => %{
          "BaseError" => [],
          "ExchangeError" => ["BaseError"],
          "RateLimitExceeded" => ["BaseError"]
        }
      }

      handle_errors = %{
        "exceptions" => %{"exact" => %{"too_many" => "RateLimitExceeded"}},
        "http_exceptions" => %{"429" => "RateLimitExceeded", "500" => "ExchangeError"}
      }

      exchange =
        exchange_with_handle_errors_and_hierarchy("clean", handle_errors, hierarchy)

      assert ContractTest.check_error_classes_covered_by_hierarchy(exchange, @base_observed) == []
    end

    test "flags class names referenced in exceptions but not in flat_parents" do
      hierarchy = %{
        "tree" => %{},
        "flat_parents" => %{"BaseError" => nil},
        "ancestors" => %{"BaseError" => []}
      }

      handle_errors = %{
        "exceptions" => %{"broad" => %{"missing" => "GhostError"}},
        "http_exceptions" => %{}
      }

      exchange = exchange_with_handle_errors_and_hierarchy("bad", handle_errors, hierarchy)

      assert [finding] =
               ContractTest.check_error_classes_covered_by_hierarchy(exchange, @base_observed)

      assert finding.invariant == "error_classes_covered_by_hierarchy"
      assert finding.message =~ "GhostError"
      assert finding.path =~ "exceptions[\"broad\"]"
    end

    test "flags class names referenced in http_exceptions but not in flat_parents" do
      hierarchy = %{
        "tree" => %{},
        "flat_parents" => %{"BaseError" => nil},
        "ancestors" => %{"BaseError" => []}
      }

      handle_errors = %{
        "exceptions" => nil,
        "http_exceptions" => %{"418" => "TeapotError"}
      }

      exchange = exchange_with_handle_errors_and_hierarchy("bad", handle_errors, hierarchy)
      findings = ContractTest.check_error_classes_covered_by_hierarchy(exchange, @base_observed)

      assert Enum.any?(findings, fn f ->
               f.path =~ "http_exceptions[\"418\"]" and f.message =~ "TeapotError"
             end)
    end

    test "no findings when handle_errors is null" do
      hierarchy = %{
        "tree" => %{},
        "flat_parents" => %{"BaseError" => nil},
        "ancestors" => %{"BaseError" => []}
      }

      exchange = exchange_with_handle_errors_and_hierarchy("emptyex", nil, hierarchy)
      assert ContractTest.check_error_classes_covered_by_hierarchy(exchange, @base_observed) == []
    end

    test "no findings when error_class_hierarchy is null (shape invariant catches that)" do
      handle_errors = %{
        "exceptions" => %{"exact" => %{"x" => "Anything"}},
        "http_exceptions" => %{}
      }

      exchange = exchange_with_handle_errors_and_hierarchy("nohier", handle_errors, nil)
      assert ContractTest.check_error_classes_covered_by_hierarchy(exchange, @base_observed) == []
    end
  end

  describe "check_normalization_shape_valid/2" do
    test "skipped on v3-shaped output (no normalization key)" do
      v3_exchange = clean_exchange()
      assert ContractTest.check_normalization_shape_valid(v3_exchange, @base_observed) == []
    end

    test "passes a freshly-built v4 normalization block" do
      exchange = %{
        "exchange" => %{"id" => "good"},
        "normalization" => CcxtExtract.Normalization.build(nil)
      }

      assert ContractTest.check_normalization_shape_valid(exchange, @base_observed) == []
    end

    test "flags missing required keys" do
      exchange = %{
        "exchange" => %{"id" => "bad"},
        "normalization" => %{"parse_methods_digest" => %{}}
      }

      findings = ContractTest.check_normalization_shape_valid(exchange, @base_observed)

      assert Enum.any?(findings, &(&1.message =~ "field_maps"))
      assert Enum.any?(findings, &(&1.message =~ "response_envelopes"))
    end

    test "flags unexpected top-level keys" do
      exchange = %{
        "exchange" => %{"id" => "bad"},
        "normalization" => Map.put(CcxtExtract.Normalization.build(nil), "rogue", true)
      }

      findings = ContractTest.check_normalization_shape_valid(exchange, @base_observed)
      assert Enum.any?(findings, &(&1.message =~ "rogue"))
    end

    test "flags malformed digest record (missing required key)" do
      block =
        nil
        |> CcxtExtract.Normalization.build()
        |> put_in(["parse_methods_digest", "parseTrade"], %{
          "params" => [],
          "return_type" => nil,
          "async" => false
          # statement_count missing
        })

      exchange = %{"exchange" => %{"id" => "bad"}, "normalization" => block}
      findings = ContractTest.check_normalization_shape_valid(exchange, @base_observed)

      assert Enum.any?(findings, fn f ->
               f.path == "normalization.parse_methods_digest.parseTrade" and
                 f.message =~ "statement_count"
             end)
    end

    test "flags wrong types in digest record" do
      block =
        nil
        |> CcxtExtract.Normalization.build()
        |> put_in(["parse_methods_digest", "parseTrade"], %{
          "params" => "not a list",
          "return_type" => 42,
          "async" => "yes",
          "statement_count" => -1
        })

      exchange = %{"exchange" => %{"id" => "bad"}, "normalization" => block}
      findings = ContractTest.check_normalization_shape_valid(exchange, @base_observed)

      assert Enum.any?(findings, &(&1.message =~ "params must be a list"))
      assert Enum.any?(findings, &(&1.message =~ "return_type must be a string or null"))
      assert Enum.any?(findings, &(&1.message =~ "async must be a boolean"))
      assert Enum.any?(findings, &(&1.message =~ "statement_count"))
    end

    test "flags malformed field_maps stub (extra parser type or wrong value type)" do
      block =
        nil
        |> CcxtExtract.Normalization.build()
        |> put_in(["field_maps", "ticker"], "not a map")
        |> put_in(["field_maps", "rogue_type"], nil)

      exchange = %{"exchange" => %{"id" => "bad"}, "normalization" => block}
      findings = ContractTest.check_normalization_shape_valid(exchange, @base_observed)

      assert Enum.any?(findings, fn f ->
               f.path == "normalization.field_maps.ticker" and
                 f.message =~ "must be null or a map"
             end)

      assert Enum.any?(findings, &(&1.message =~ "rogue_type"))
    end

    test "non-map normalization is flagged" do
      exchange = %{"exchange" => %{"id" => "bad"}, "normalization" => "garbage"}
      [finding] = ContractTest.check_normalization_shape_valid(exchange, @base_observed)
      assert finding.message =~ "must be a map"
    end
  end

  describe "check_parse_methods_digest_covers_inventory/2" do
    test "skipped on v3-shaped output (no normalization key)" do
      v3_exchange = clean_exchange()
      observed = Map.put(@base_observed, :parse_methods_inventory, %{"good" => ["parseTrade"]})
      assert ContractTest.check_parse_methods_digest_covers_inventory(v3_exchange, observed) == []
    end

    test "no findings when digest covers inventory exactly" do
      block =
        CcxtExtract.Normalization.build(%{
          "parse_methods" => %{
            "parseTrade" => %{"statements" => 1, "params" => [], "async" => false},
            "parseTicker" => %{"statements" => 1, "params" => [], "async" => false}
          }
        })

      exchange = %{"exchange" => %{"id" => "good"}, "normalization" => block}
      observed = Map.put(@base_observed, :parse_methods_inventory, %{"good" => ["parseTrade", "parseTicker"]})

      assert ContractTest.check_parse_methods_digest_covers_inventory(exchange, observed) == []
    end

    test "flags missing inventory methods (lossy projection)" do
      block =
        CcxtExtract.Normalization.build(%{
          "parse_methods" => %{
            "parseTrade" => %{"statements" => 1, "params" => [], "async" => false}
          }
        })

      exchange = %{"exchange" => %{"id" => "drift"}, "normalization" => block}

      observed =
        Map.put(@base_observed, :parse_methods_inventory, %{
          "drift" => ["parseTrade", "parseTicker"]
        })

      [finding] = ContractTest.check_parse_methods_digest_covers_inventory(exchange, observed)
      assert finding.exchange == "drift"
      assert finding.invariant == "parse_methods_digest_covers_inventory"
      assert finding.path == "normalization.parse_methods_digest.parseTicker"
      assert finding.message =~ "parseTicker"
    end

    test "skipped when inventory has no entry for the exchange" do
      block = CcxtExtract.Normalization.build(nil)
      exchange = %{"exchange" => %{"id" => "ghost"}, "normalization" => block}
      observed = Map.put(@base_observed, :parse_methods_inventory, %{})

      assert ContractTest.check_parse_methods_digest_covers_inventory(exchange, observed) == []
    end

    test "skipped when observed has no inventory key at all" do
      block = CcxtExtract.Normalization.build(nil)
      exchange = %{"exchange" => %{"id" => "x"}, "normalization" => block}
      assert ContractTest.check_parse_methods_digest_covers_inventory(exchange, @base_observed) == []
    end

    test "findings sorted by method name" do
      block = CcxtExtract.Normalization.build(nil)

      exchange = %{"exchange" => %{"id" => "z"}, "normalization" => block}

      observed =
        Map.put(@base_observed, :parse_methods_inventory, %{
          "z" => ["parseTicker", "parseAccount", "parseTrade"]
        })

      findings = ContractTest.check_parse_methods_digest_covers_inventory(exchange, observed)
      method_names = Enum.map(findings, & &1.path)

      assert method_names == [
               "normalization.parse_methods_digest.parseAccount",
               "normalization.parse_methods_digest.parseTicker",
               "normalization.parse_methods_digest.parseTrade"
             ]
    end
  end

  describe "check_handle_errors_retryable_shape_valid/2" do
    test "no findings on schema-conformant fixture (all three fields nil)" do
      assert ContractTest.check_handle_errors_retryable_shape_valid(clean_exchange(), @base_observed) == []
    end

    test "no findings when error_status_map and error_retryable are well-formed" do
      exchange =
        clean_exchange()
        |> put_in(
          ["structure", "error_status_map"],
          %{
            "418" => [%{"class" => "DDoSProtection", "source" => "http_exceptions"}],
            "429" => [%{"class" => "RateLimitExceeded", "source" => "throw_dispatch_predicate"}]
          }
        )
        |> put_in(
          ["structure", "error_retryable"],
          %{
            "rate_limit" => ["DDoSProtection", "RateLimitExceeded"],
            "auth" => [],
            "server_busy" => [],
            "network" => [],
            "non_retryable" => []
          }
        )

      assert ContractTest.check_handle_errors_retryable_shape_valid(exchange, @base_observed) == []
    end

    test "non-numeric status key produces a finding" do
      exchange =
        put_in(clean_exchange(), ["structure", "error_status_map"], %{
          "abc" => [%{"class" => "DDoSProtection", "source" => "http_exceptions"}]
        })

      assert [finding] = ContractTest.check_handle_errors_retryable_shape_valid(exchange, @base_observed)
      assert finding.invariant == "handle_errors_retryable_shape_valid"
      assert finding.path == "structure.error_status_map"
      assert finding.message =~ "not a numeric HTTP status string"
    end

    test "out-of-vocabulary source produces a finding" do
      exchange =
        put_in(clean_exchange(), ["structure", "error_status_map"], %{
          "418" => [%{"class" => "DDoSProtection", "source" => "fabricated"}]
        })

      assert [finding] = ContractTest.check_handle_errors_retryable_shape_valid(exchange, @base_observed)
      assert finding.message =~ "source"
      assert finding.message =~ "vocabulary"
    end

    test "missing required bucket produces a finding" do
      exchange =
        put_in(clean_exchange(), ["structure", "error_retryable"], %{
          "rate_limit" => [],
          "auth" => [],
          "server_busy" => [],
          "network" => []
          # non_retryable missing
        })

      findings = ContractTest.check_handle_errors_retryable_shape_valid(exchange, @base_observed)
      assert Enum.any?(findings, fn f -> f.message =~ "missing required bucket" and f.message =~ "non_retryable" end)
    end

    test "extra bucket produces a finding" do
      exchange =
        put_in(clean_exchange(), ["structure", "error_retryable"], %{
          "rate_limit" => [],
          "auth" => [],
          "server_busy" => [],
          "network" => [],
          "non_retryable" => [],
          "made_up" => ["foo"]
        })

      findings = ContractTest.check_handle_errors_retryable_shape_valid(exchange, @base_observed)
      assert Enum.any?(findings, fn f -> f.message =~ "unexpected bucket" and f.message =~ "made_up" end)
    end

    test "class in wrong bucket produces a finding" do
      exchange =
        put_in(clean_exchange(), ["structure", "error_retryable"], %{
          "rate_limit" => ["InvalidOrder"],
          "auth" => [],
          "server_busy" => [],
          "network" => [],
          "non_retryable" => []
        })

      findings = ContractTest.check_handle_errors_retryable_shape_valid(exchange, @base_observed)

      assert Enum.any?(findings, fn f ->
               f.message =~ "InvalidOrder" and f.message =~ "non_retryable" and f.message =~ "rate_limit"
             end)
    end

    test "unsorted bucket list produces a finding" do
      exchange =
        put_in(clean_exchange(), ["structure", "error_retryable"], %{
          "rate_limit" => ["RateLimitExceeded", "DDoSProtection"],
          "auth" => [],
          "server_busy" => [],
          "network" => [],
          "non_retryable" => []
        })

      findings = ContractTest.check_handle_errors_retryable_shape_valid(exchange, @base_observed)
      assert Enum.any?(findings, fn f -> f.message =~ "sorted and unique" end)
    end
  end

  describe "check_handler_dispatch_v4_shape_valid/2" do
    test "no findings on v3-shaped exchange (short-circuit)" do
      # clean_exchange returns a v3-shaped fixture (has 'structure', no 'endpoints')
      assert ContractTest.check_handler_dispatch_v4_shape_valid(clean_exchange(), @base_observed) == []
    end

    test "no findings on well-formed v4 endpoints.handlers" do
      v4_exchange = %{
        "id" => "v4ex",
        "exchange" => %{"id" => "v4ex"},
        "endpoints" => %{
          "handlers" => %{
            "error" => [],
            "signing" => %{"sections" => [], "branches" => []},
            "parse" => %{}
          }
        }
      }

      assert ContractTest.check_handler_dispatch_v4_shape_valid(v4_exchange, @base_observed) == []
    end

    test "all-null v4 handlers are valid (alias exchange shape)" do
      v4_exchange = %{
        "id" => "aliasex",
        "exchange" => %{"id" => "aliasex"},
        "endpoints" => %{"handlers" => %{"error" => nil, "signing" => nil, "parse" => nil}}
      }

      assert ContractTest.check_handler_dispatch_v4_shape_valid(v4_exchange, @base_observed) == []
    end

    test "missing required handler key produces a finding" do
      v4_exchange = %{
        "id" => "v4ex",
        "exchange" => %{"id" => "v4ex"},
        "endpoints" => %{"handlers" => %{"error" => [], "signing" => nil}}
      }

      findings = ContractTest.check_handler_dispatch_v4_shape_valid(v4_exchange, @base_observed)
      assert Enum.any?(findings, fn f -> f.message =~ "missing required key" and f.message =~ "parse" end)
    end

    test "extra handler key produces a finding" do
      v4_exchange = %{
        "id" => "v4ex",
        "exchange" => %{"id" => "v4ex"},
        "endpoints" => %{
          "handlers" => %{"error" => [], "signing" => nil, "parse" => %{}, "extras" => "oops"}
        }
      }

      findings = ContractTest.check_handler_dispatch_v4_shape_valid(v4_exchange, @base_observed)
      assert Enum.any?(findings, fn f -> f.message =~ "unexpected key" and f.message =~ "extras" end)
    end

    test "wrong leaf type produces a finding" do
      v4_exchange = %{
        "id" => "v4ex",
        "exchange" => %{"id" => "v4ex"},
        "endpoints" => %{"handlers" => %{"error" => "not a list", "signing" => nil, "parse" => nil}}
      }

      findings = ContractTest.check_handler_dispatch_v4_shape_valid(v4_exchange, @base_observed)
      assert Enum.any?(findings, fn f -> f.path == "endpoints.handlers.error" and f.message =~ "list" end)
    end

    test "missing endpoints.handlers in v4 exchange produces a finding" do
      v4_exchange = %{
        "id" => "v4ex",
        "exchange" => %{"id" => "v4ex"},
        "endpoints" => %{}
      }

      findings = ContractTest.check_handler_dispatch_v4_shape_valid(v4_exchange, @base_observed)
      assert Enum.any?(findings, fn f -> f.path == "endpoints.handlers" and f.message =~ "missing" end)
    end
  end

  describe "check_rate_limits_endpoint_cost_binding_coherent/2" do
    test "no-op on v3-shaped exchange (short-circuit)" do
      assert ContractTest.check_rate_limits_endpoint_cost_binding_coherent(clean_exchange(), @base_observed) == []
    end

    test "no findings when endpoint_cost_binding matches derive(rate_limits.buckets)" do
      buckets = %{
        "buckets" => [
          %{
            "axes" => ["request"],
            "rate_limit_ms" => 50.0,
            "refill_per_sec" => 20.0,
            "max_size" => 1.0,
            "cost_default" => 1.0,
            "algorithm" => "leakyBucket",
            "rolling_window_ms" => 0.0
          }
        ],
        "source" => "describe",
        "unresolved_reason" => nil
      }

      binding = CcxtExtract.RateLimitCostBinding.derive(buckets)

      v4_exchange = %{
        "id" => "v4ex",
        "exchange" => %{"id" => "v4ex"},
        "endpoints" => %{},
        "rate_limits" => %{
          "buckets" => buckets,
          "per_endpoint_cost" => nil,
          "endpoint_cost_binding" => binding
        }
      }

      assert ContractTest.check_rate_limits_endpoint_cost_binding_coherent(v4_exchange, @base_observed) == []
    end

    test "finding when endpoint_cost_binding contradicts bucket wrapper" do
      buckets = %{
        "buckets" => [],
        "source" => "describe",
        "unresolved_reason" => nil
      }

      v4_exchange = %{
        "id" => "driftex",
        "exchange" => %{"id" => "driftex"},
        "endpoints" => %{},
        "rate_limits" => %{
          "buckets" => buckets,
          "per_endpoint_cost" => nil,
          "endpoint_cost_binding" => %{"bucket_index" => 0, "axes" => ["request"]}
        }
      }

      findings = ContractTest.check_rate_limits_endpoint_cost_binding_coherent(v4_exchange, @base_observed)
      assert length(findings) == 1
      assert hd(findings).invariant == "rate_limits_endpoint_cost_binding_coherent"
      assert hd(findings).exchange == "driftex"
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

    test "skips exchange_v3.json (schema copy) alongside per-exchange JSON", %{tmp: tmp} do
      File.write!(Path.join(tmp, "real.json"), Jason.encode!(%{"id" => "real"}))
      File.write!(Path.join(tmp, "exchange_v3.json"), Jason.encode!(%{"$schema" => "x"}))
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

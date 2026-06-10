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
  alias CcxtExtract.ContractTest.Finding

  @base_observed %{error_code_fields_roots: ["response"]}

  defp clean_exchange, do: schema_conformant("good")

  describe "check_request_defaults_resolvable_reachable_from_unified/2" do
    defp literal_entry(value), do: %{"value" => value, "kind" => "literal", "reason" => nil}
    defp unresolved_entry(reason), do: %{"value" => nil, "kind" => "unresolved", "reason" => reason}

    test "no finding when literal method is a direct unified_endpoints key" do
      exchange = %{
        "id" => "goodex",
        "endpoints" => %{
          "unified" => %{"fetchTime" => ["publicPostInfo"]},
          "request" => %{"defaults" => %{"fetchTime" => %{"type" => literal_entry("exchangeStatus")}}}
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
        "endpoints" => %{
          "unified" => %{"fetchTime" => ["publicPostInfo", "fetchTimeHelper"]},
          "request" => %{
            "defaults" => %{
              "fetchTimeHelper" => %{"type" => literal_entry("exchangeStatus")}
            }
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
        "endpoints" => %{
          "unified" => %{"fetchTicker" => ["publicGetTicker"]},
          "request" => %{
            "defaults" => %{
              "fetchOrphan" => %{"type" => literal_entry("x")}
            }
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
      assert finding.path == "endpoints.request.defaults.fetchOrphan"
      assert finding.message =~ "fetchOrphan"
    end

    test "unresolved-only method is ignored even when unreachable" do
      exchange = %{
        "id" => "unresolvedex",
        "endpoints" => %{
          "unified" => %{"fetchTicker" => ["publicGetTicker"]},
          "request" => %{
            "defaults" => %{
              "fetchOrphan" => %{"type" => unresolved_entry("identifier_reference")}
            }
          }
        }
      }

      assert ContractTest.check_request_defaults_resolvable_reachable_from_unified(
               exchange,
               @base_observed
             ) == []
    end

    test "no finding when request_defaults is absent or empty" do
      exchange = %{"id" => "emptyex", "endpoints" => %{"unified" => %{}}}

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
        "raw" => %{"describe" => %{"has" => %{"fetchOHLCV" => true, "fetchTicker" => true}}},
        "endpoints" => %{"unified" => %{"fetchOHLCV" => ["pubGetKlines"]}}
      }

      assert ContractTest.check_unified_endpoints_claimed_in_has(exchange, @base_observed) == []
    end

    test "finding when unified_endpoints declares a key that has does not claim true" do
      exchange = %{
        "id" => "badex",
        "raw" => %{"describe" => %{"has" => %{"fetchOHLCV" => "__undefined"}}},
        "endpoints" => %{"unified" => %{"fetchOHLCV" => ["pubGetKlines"]}}
      }

      [finding] = ContractTest.check_unified_endpoints_claimed_in_has(exchange, @base_observed)
      assert finding.exchange == "badex"
      assert finding.invariant == "unified_endpoints_claimed_in_has"
      assert finding.path == "endpoints.unified.fetchOHLCV"
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
        "raw" => %{"describe" => %{"api" => %{"private" => %{}, "public" => %{}}}},
        "auth" => %{"authenticated_sections" => ["private"]}
      }

      assert ContractTest.check_authenticated_sections_reachable_in_api(exchange, @base_observed) ==
               []
    end

    test "no finding when section is nested under another api grouping" do
      exchange = %{
        "id" => "nestedex",
        "raw" => %{
          "describe" => %{"api" => %{"v2" => %{"private" => %{}}, "v3" => %{"private" => %{}}}}
        },
        "auth" => %{"authenticated_sections" => ["private"]}
      }

      assert ContractTest.check_authenticated_sections_reachable_in_api(exchange, @base_observed) ==
               []
    end

    test "finding when section is nowhere in the api tree" do
      exchange = %{
        "id" => "missingex",
        "raw" => %{"describe" => %{"api" => %{"public" => %{}}}},
        "auth" => %{"authenticated_sections" => ["wapi"]}
      }

      [finding] =
        ContractTest.check_authenticated_sections_reachable_in_api(exchange, @base_observed)

      assert finding.exchange == "missingex"
      assert finding.invariant == "authenticated_sections_reachable_in_api"
      assert finding.path == "auth.authenticated_sections[0]"
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
        "errors" => %{
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
        "errors" => %{
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
      assert finding.path == "errors.handle_errors.error_code_fields[0].object"
      assert finding.message =~ "unusualRoot"
    end

    test "finding points at object_path when root comes from object_path" do
      exchange = %{
        "id" => "pathdrift",
        "errors" => %{
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
      assert finding.path == "errors.handle_errors.error_code_fields[0].object_path"
      assert finding.message =~ "unexpected"
    end

    test "no finding when parents are missing" do
      exchange = %{"id" => "emptyex"}
      assert ContractTest.check_error_code_fields_root(exchange, @base_observed) == []
    end
  end

  describe "check_override_paths_present_in_output/2" do
    test "no findings when exchange has no override file" do
      exchange = %{"exchange" => %{"id" => "__no_override_#{System.unique_integer([:positive])}__"}}
      assert ContractTest.check_override_paths_present_in_output(exchange, @base_observed) == []
    end

    test "no findings when v4 output carries the override at its translated path" do
      # v4-shaped exchange — the helper sees `endpoints` and translates the
      # override pointer `/structure/authenticated_sections` to
      # `/auth/authenticated_sections` before walking.
      exchange =
        clean_exchange()
        |> put_in(["exchange", "id"], "hyperliquid")
        |> put_in(["auth", "authenticated_sections"], ["private"])

      assert ContractTest.check_override_paths_present_in_output(exchange, @base_observed) == []
    end

    test "finding when v4 exchange output drifts from override value" do
      # hyperliquid's authenticated_sections override — v4-shaped exchange
      # carries a drifted value. `finding.path` is the translated v4 pointer.
      exchange =
        clean_exchange()
        |> put_in(["exchange", "id"], "hyperliquid")
        |> put_in(["auth", "authenticated_sections"], ["drifted"])

      [finding] = ContractTest.check_override_paths_present_in_output(exchange, @base_observed)

      assert finding.exchange == "hyperliquid"
      assert finding.invariant == "override_paths_present_in_output"
      assert finding.path == "/auth/authenticated_sections"
      assert finding.message =~ "drifted"
    end
  end

  describe "check_provenance_covers_schema/2" do
    test "no findings when every declared pointer resolves and tags match" do
      assert ContractTest.check_provenance_covers_schema(clean_exchange(), @base_observed) == []
    end

    test "uncovered_section finding when pipeline emits a section Provenance does not declare" do
      # Plant an undeclared top-level v4 section (must be under a declared
      # provenance root from @provenance_section_roots to be walked).
      exchange = put_in(clean_exchange(), ["raw", "new_undeclared_section"], %{})

      [finding] = ContractTest.check_provenance_covers_schema(exchange, @base_observed)
      assert finding.invariant == "provenance_covers_schema"
      assert finding.path == "/raw/new_undeclared_section"
      assert finding.message =~ "not declared in Provenance"
    end

    test "orphan_declaration finding when a declared pointer does not resolve in output" do
      # Drop /endpoints/pagination entirely from the exchange.
      exchange = update_in(clean_exchange(), ["endpoints"], &Map.delete(&1, "pagination"))

      findings = ContractTest.check_provenance_covers_schema(exchange, @base_observed)
      paths = Enum.map(findings, & &1.path)
      assert "/endpoints/pagination" in paths
      assert Enum.all?(findings, &(&1.invariant == "provenance_covers_schema"))
    end

    test "tag_mismatch finding when _provenance tag disagrees with predicted split" do
      # /raw/describe is declared raw; flip to "derived" in the map.
      exchange = put_in(clean_exchange(), ["_provenance", "/raw/describe"], "derived")

      findings = ContractTest.check_provenance_covers_schema(exchange, @base_observed)
      mismatch = Enum.find(findings, &(&1.path == "/raw/describe"))
      assert mismatch
      assert mismatch.invariant == "provenance_covers_schema"
      assert mismatch.message =~ "expected \"raw\""
      assert mismatch.message =~ "got \"derived\""
    end

    test "override tag is always accepted regardless of predicted split" do
      # Flip a raw pointer to "override" — should produce NO tag_mismatch.
      exchange = put_in(clean_exchange(), ["_provenance", "/raw/describe"], "override")

      findings = ContractTest.check_provenance_covers_schema(exchange, @base_observed)

      refute Enum.any?(
               findings,
               &(&1.path == "/raw/describe" and &1.invariant == "provenance_covers_schema")
             )
    end

    test "nil parent is vacuously resolved (Honesty Rule) — no orphan findings for its subkeys" do
      # /errors/handle_errors = nil legitimately means "extractor produced
      # nothing"; the declared subkeys should NOT be flagged as orphans.
      exchange = put_in(clean_exchange(), ["errors", "handle_errors"], nil)

      findings = ContractTest.check_provenance_covers_schema(exchange, @base_observed)

      refute Enum.any?(findings, &String.starts_with?(&1.path, "/errors/handle_errors"))
    end

    test "override path tag suppresses uncovered_section even for undeclared pointers" do
      # Undeclared section under a declared root + override tag → no uncovered finding.
      exchange =
        clean_exchange()
        |> put_in(["raw", "custom_override"], %{})
        |> put_in(["_provenance", "/raw/custom_override"], "override")

      findings = ContractTest.check_provenance_covers_schema(exchange, @base_observed)
      refute Enum.any?(findings, &(&1.path == "/raw/custom_override"))
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
      |> put_in(["auth", "sign_recipe"], recipe_map)
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
      assert finding.path == "auth.sign_recipe.private"
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
      assert finding.path == "auth.sign_recipe.private"
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
      assert Enum.at(findings, 0).path == "auth.sign_recipe.aprivate"
      assert Enum.at(findings, 1).path == "auth.sign_recipe.zprivate"
    end
  end

  describe "check_websocket_heartbeat_shape_valid/2" do
    alias CcxtExtract.WsHeartbeat

    defp ws_exchange(id, heartbeat) do
      %{"exchange" => %{"id" => id}, "websocket" => %{"heartbeat" => heartbeat}}
    end

    test "no findings on the honest-empty none_record" do
      exchange = ws_exchange("restonly", WsHeartbeat.none_record())
      assert ContractTest.check_websocket_heartbeat_shape_valid(exchange, @base_observed) == []
    end

    test "no findings on a freshly-derived record" do
      entry = %{
        "id" => "okx",
        "extends" => "okxRest",
        "ping" => %{
          "defined" => true,
          "shape" => "string",
          "return_value" => %{"value" => "ping", "kind" => "literal", "reason" => nil}
        },
        "pong_methods" => %{"pong" => false, "handlePong" => true, "handlePing" => false},
        "streaming" => %{
          "present" => true,
          "keep_alive_ms" => 18_000,
          "max_ping_pong_misses" => nil,
          "has_ping_property" => true
        }
      }

      exchange = ws_exchange("okx", WsHeartbeat.build(entry, %{"okx" => entry}))
      assert ContractTest.check_websocket_heartbeat_shape_valid(exchange, @base_observed) == []
    end

    test "non-map heartbeat is flagged" do
      [finding] =
        ContractTest.check_websocket_heartbeat_shape_valid(
          ws_exchange("bad", "garbage"),
          @base_observed
        )

      assert finding.exchange == "bad"
      assert finding.invariant == "websocket_heartbeat_shape_valid"
      assert finding.path == "websocket/heartbeat"
      assert finding.message =~ "must be a map"
    end

    test "a missing required key is flagged" do
      record = Map.delete(WsHeartbeat.none_record(), "keep_alive_ms")

      [finding] =
        ContractTest.check_websocket_heartbeat_shape_valid(
          ws_exchange("bad", record),
          @base_observed
        )

      assert finding.message =~ "missing required key"
      assert finding.message =~ "keep_alive_ms"
    end

    test "an unexpected key is flagged" do
      record = Map.put(WsHeartbeat.none_record(), "rogue", true)

      [finding] =
        ContractTest.check_websocket_heartbeat_shape_valid(
          ws_exchange("bad", record),
          @base_observed
        )

      assert finding.message =~ "unexpected key"
      assert finding.message =~ "rogue"
    end

    test "an out-of-vocabulary ping_kind is flagged" do
      record = Map.put(WsHeartbeat.none_record(), "ping_kind", "bogus")

      findings =
        ContractTest.check_websocket_heartbeat_shape_valid(
          ws_exchange("bad", record),
          @base_observed
        )

      assert Enum.any?(findings, &(&1.message =~ "ping_kind must be one of"))
    end

    test "an out-of-vocabulary source is flagged" do
      record = Map.put(WsHeartbeat.none_record(), "source", "bogus")

      findings =
        ContractTest.check_websocket_heartbeat_shape_valid(
          ws_exchange("bad", record),
          @base_observed
        )

      assert Enum.any?(findings, &(&1.message =~ "source must be one of"))
    end

    test "an out-of-vocabulary unresolved_reason is flagged" do
      record = Map.put(WsHeartbeat.none_record(), "unresolved_reason", "bogus")

      findings =
        ContractTest.check_websocket_heartbeat_shape_valid(
          ws_exchange("bad", record),
          @base_observed
        )

      assert Enum.any?(findings, &(&1.message =~ "unresolved_reason must be one of"))
    end

    test "ping_kind=none disagreeing with unresolved_reason is flagged (honesty rule)" do
      record = Map.put(WsHeartbeat.none_record(), "unresolved_reason", nil)

      [finding] =
        ContractTest.check_websocket_heartbeat_shape_valid(
          ws_exchange("incoherent", record),
          @base_observed
        )

      assert finding.message =~ "ping_kind=none must agree with unresolved_reason=no_ws_support"
    end

    test "ping_kind=none disagreeing with source is flagged (honesty rule)" do
      record = Map.put(WsHeartbeat.none_record(), "source", "pro_describe")

      [finding] =
        ContractTest.check_websocket_heartbeat_shape_valid(
          ws_exchange("incoherent", record),
          @base_observed
        )

      assert finding.message =~ "ping_kind=none must agree with source=none"
    end

    test "ping_kind=none disagreeing with keep_alive_ms is flagged (honesty rule)" do
      record = Map.put(WsHeartbeat.none_record(), "keep_alive_ms", 30_000)

      [finding] =
        ContractTest.check_websocket_heartbeat_shape_valid(
          ws_exchange("incoherent", record),
          @base_observed
        )

      assert finding.message =~ "ping_kind=none must agree with keep_alive_ms=null"
    end

    test "ping_kind=unknown disagreeing with unresolved_reason is flagged (honesty rule)" do
      entry = %{
        "id" => "oddex",
        "extends" => "oddexRest",
        "ping" => %{"defined" => true, "shape" => "other", "return_value" => nil},
        "pong_methods" => %{"pong" => false, "handlePong" => false, "handlePing" => false},
        "streaming" => %{
          "present" => false,
          "keep_alive_ms" => nil,
          "max_ping_pong_misses" => nil,
          "has_ping_property" => false
        }
      }

      record = Map.put(WsHeartbeat.build(entry, %{"oddex" => entry}), "unresolved_reason", nil)

      [finding] =
        ContractTest.check_websocket_heartbeat_shape_valid(
          ws_exchange("incoherent", record),
          @base_observed
        )

      assert finding.message =~
               "ping_kind=unknown must agree with unresolved_reason=ping_return_not_literal"
    end

    test "ping_kind=none carrying a populated ping_payload is flagged (honesty rule)" do
      record = Map.put(WsHeartbeat.none_record(), "ping_payload", "ping")

      [finding] =
        ContractTest.check_websocket_heartbeat_shape_valid(
          ws_exchange("incoherent", record),
          @base_observed
        )

      assert finding.message =~ "ping_kind=none must agree with ping_payload=null"
    end

    test "ping_kind=none carrying a populated ping_payload_kind is flagged (honesty rule)" do
      record = Map.put(WsHeartbeat.none_record(), "ping_payload_kind", "literal")

      [finding] =
        ContractTest.check_websocket_heartbeat_shape_valid(
          ws_exchange("incoherent", record),
          @base_observed
        )

      assert finding.message =~ "ping_kind=none must agree with ping_payload_kind=null"
    end

    test "ping_kind=none carrying a populated max_ping_pong_misses is flagged (honesty rule)" do
      record = Map.put(WsHeartbeat.none_record(), "max_ping_pong_misses", 2.0)

      [finding] =
        ContractTest.check_websocket_heartbeat_shape_valid(
          ws_exchange("incoherent", record),
          @base_observed
        )

      assert finding.message =~ "ping_kind=none must agree with max_ping_pong_misses=null"
    end

    test "ping_kind=none carrying a populated keep_alive_resolved_from is flagged (honesty rule)" do
      record = Map.put(WsHeartbeat.none_record(), "keep_alive_resolved_from", "self")

      [finding] =
        ContractTest.check_websocket_heartbeat_shape_valid(
          ws_exchange("incoherent", record),
          @base_observed
        )

      assert finding.message =~ "ping_kind=none must agree with keep_alive_resolved_from=null"
    end

    test "ping_kind=none with has_pong_handler=true is flagged (honesty rule)" do
      record = Map.put(WsHeartbeat.none_record(), "has_pong_handler", true)

      [finding] =
        ContractTest.check_websocket_heartbeat_shape_valid(
          ws_exchange("incoherent", record),
          @base_observed
        )

      assert finding.message =~ "ping_kind=none must agree with has_pong_handler=false"
    end
  end

  describe "check_error_class_hierarchy_shape_valid/2" do
    defp exchange_with_hierarchy(id, hierarchy) do
      %{
        "exchange" => %{"id" => id},
        "errors" => %{"class_hierarchy" => hierarchy}
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
        "errors" => %{
          "handle_errors" => handle_errors,
          "class_hierarchy" => hierarchy
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

  describe "check_error_class_hierarchy_content_equals_baseline/2" do
    test "no finding when record exactly matches the provided baseline" do
      h = %{
        "tree" => %{"BaseError" => %{}},
        "flat_parents" => %{"BaseError" => nil},
        "ancestors" => %{"BaseError" => []}
      }

      exchange = %{
        "exchange" => %{"id" => "good"},
        "errors" => %{"class_hierarchy" => h}
      }

      assert ContractTest.check_error_class_hierarchy_content_equals_baseline(
               exchange,
               %{error_class_hierarchy: h}
             ) == []
    end

    test "finding when tree/parents/ancestors differ from baseline" do
      baseline = %{
        "tree" => %{"BaseError" => %{}},
        "flat_parents" => %{"BaseError" => nil},
        "ancestors" => %{"BaseError" => []}
      }

      drifted = %{
        "tree" => %{"BaseError" => %{"Ghost" => %{}}},
        "flat_parents" => %{"BaseError" => nil, "Ghost" => "BaseError"},
        "ancestors" => %{"BaseError" => [], "Ghost" => ["BaseError"]}
      }

      exchange = %{
        "exchange" => %{"id" => "drift"},
        "errors" => %{"class_hierarchy" => drifted}
      }

      [finding] =
        ContractTest.check_error_class_hierarchy_content_equals_baseline(
          exchange,
          %{error_class_hierarchy: baseline}
        )

      assert finding.exchange == "drift"
      assert finding.invariant == "error_class_hierarchy_content_equals_baseline"
      assert finding.path == "errors.class_hierarchy"
      assert finding.message =~ "differs from baseline"
    end

    test "no finding when class_hierarchy is null (missing-data case)" do
      exchange = %{
        "exchange" => %{"id" => "nullex"},
        "errors" => %{"class_hierarchy" => nil}
      }

      assert ContractTest.check_error_class_hierarchy_content_equals_baseline(
               exchange,
               %{error_class_hierarchy: %{}}
             ) == []
    end

    test "no finding when no hierarchy baseline in observed (graceful for partial test contexts)" do
      h = %{"tree" => %{}, "flat_parents" => %{}, "ancestors" => %{}}
      exchange = %{"exchange" => %{"id" => "x"}, "errors" => %{"class_hierarchy" => h}}
      assert ContractTest.check_error_class_hierarchy_content_equals_baseline(exchange, @base_observed) == []
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
    test "skipped when output is missing the normalization key entirely" do
      # Pre-Task 117 / non-v4 shapes (and any future shape that doesn't carry
      # `normalization`) hit the short-circuit and produce no findings.
      bare = %{"exchange" => %{"id" => "good"}}
      observed = Map.put(@base_observed, :parse_methods_inventory, %{"good" => ["parseTrade"]})
      assert ContractTest.check_parse_methods_digest_covers_inventory(bare, observed) == []
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
          ["errors", "status_map"],
          %{
            "418" => [%{"class" => "DDoSProtection", "source" => "http_exceptions"}],
            "429" => [%{"class" => "RateLimitExceeded", "source" => "throw_dispatch_predicate"}]
          }
        )
        |> put_in(
          ["errors", "retry_classification"],
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
        put_in(clean_exchange(), ["errors", "status_map"], %{
          "abc" => [%{"class" => "DDoSProtection", "source" => "http_exceptions"}]
        })

      assert [finding] = ContractTest.check_handle_errors_retryable_shape_valid(exchange, @base_observed)
      assert finding.invariant == "handle_errors_retryable_shape_valid"
      assert finding.path == "errors.status_map"
      assert finding.message =~ "not a numeric HTTP status string"
    end

    test "out-of-vocabulary source produces a finding" do
      exchange =
        put_in(clean_exchange(), ["errors", "status_map"], %{
          "418" => [%{"class" => "DDoSProtection", "source" => "fabricated"}]
        })

      assert [finding] = ContractTest.check_handle_errors_retryable_shape_valid(exchange, @base_observed)
      assert finding.message =~ "source"
      assert finding.message =~ "vocabulary"
    end

    test "missing required bucket produces a finding" do
      exchange =
        put_in(clean_exchange(), ["errors", "retry_classification"], %{
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
        put_in(clean_exchange(), ["errors", "retry_classification"], %{
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
        put_in(clean_exchange(), ["errors", "retry_classification"], %{
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
        put_in(clean_exchange(), ["errors", "retry_classification"], %{
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

  describe "check_handler_dispatch_shape_valid/2" do
    test "no findings on clean v4 fixture with nil handlers" do
      # clean_exchange returns a v4-shaped fixture with `endpoints.handlers`
      # populated as `%{"error" => nil, "signing" => nil, "parse" => nil}`
      # (all nullable per the schema).
      assert ContractTest.check_handler_dispatch_shape_valid(clean_exchange(), @base_observed) == []
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

      assert ContractTest.check_handler_dispatch_shape_valid(v4_exchange, @base_observed) == []
    end

    test "all-null v4 handlers are valid (alias exchange shape)" do
      v4_exchange = %{
        "id" => "aliasex",
        "exchange" => %{"id" => "aliasex"},
        "endpoints" => %{"handlers" => %{"error" => nil, "signing" => nil, "parse" => nil}}
      }

      assert ContractTest.check_handler_dispatch_shape_valid(v4_exchange, @base_observed) == []
    end

    test "missing required handler key produces a finding" do
      v4_exchange = %{
        "id" => "v4ex",
        "exchange" => %{"id" => "v4ex"},
        "endpoints" => %{"handlers" => %{"error" => [], "signing" => nil}}
      }

      findings = ContractTest.check_handler_dispatch_shape_valid(v4_exchange, @base_observed)
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

      findings = ContractTest.check_handler_dispatch_shape_valid(v4_exchange, @base_observed)
      assert Enum.any?(findings, fn f -> f.message =~ "unexpected key" and f.message =~ "extras" end)
    end

    test "wrong leaf type produces a finding" do
      v4_exchange = %{
        "id" => "v4ex",
        "exchange" => %{"id" => "v4ex"},
        "endpoints" => %{"handlers" => %{"error" => "not a list", "signing" => nil, "parse" => nil}}
      }

      findings = ContractTest.check_handler_dispatch_shape_valid(v4_exchange, @base_observed)
      assert Enum.any?(findings, fn f -> f.path == "endpoints.handlers.error" and f.message =~ "list" end)
    end

    test "missing endpoints.handlers in v4 exchange produces a finding" do
      v4_exchange = %{
        "id" => "v4ex",
        "exchange" => %{"id" => "v4ex"},
        "endpoints" => %{}
      }

      findings = ContractTest.check_handler_dispatch_shape_valid(v4_exchange, @base_observed)
      assert Enum.any?(findings, fn f -> f.path == "endpoints.handlers" and f.message =~ "missing" end)
    end
  end

  describe "check_rate_limits_endpoint_cost_binding_coherent/2" do
    test "no findings when wrapper + binding both null (clean v4 fixture)" do
      # clean_exchange has rate_limits.buckets as an empty record and
      # endpoint_cost_binding as nil — derive(wrapper) returns nil too,
      # so the binding matches and no finding is emitted.
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

  describe "check_transaction_classification_promoted_flags_consistent/2" do
    defp tc_exchange(id, classification) do
      %{
        "exchange" => %{"id" => id},
        "endpoints" => %{"transaction_classification" => classification}
      }
    end

    test "no findings when every on_chain entry is also transactional" do
      exchange =
        tc_exchange("goodex", %{
          "createOrder" => %{"transactional" => true, "on_chain" => false},
          "withdraw" => %{"transactional" => true, "on_chain" => true},
          "fetchTicker" => %{"transactional" => false, "on_chain" => false}
        })

      assert ContractTest.check_transaction_classification_promoted_flags_consistent(
               exchange,
               @base_observed
             ) == []
    end

    test "finding when on_chain=true but transactional=false (the gate violation)" do
      exchange =
        tc_exchange("badex", %{"sendTx" => %{"transactional" => false, "on_chain" => true}})

      [finding] =
        ContractTest.check_transaction_classification_promoted_flags_consistent(
          exchange,
          @base_observed
        )

      assert finding.exchange == "badex"
      assert finding.invariant == "transaction_classification_promoted_flags_consistent"
      assert finding.path == "endpoints.transaction_classification.sendTx"
      assert finding.message =~ "on_chain=true"
      assert finding.message =~ "transactional=false"
    end

    test "finding when on_chain=true but transactional key is missing" do
      exchange = tc_exchange("missingex", %{"weird" => %{"on_chain" => true}})

      [finding] =
        ContractTest.check_transaction_classification_promoted_flags_consistent(
          exchange,
          @base_observed
        )

      assert finding.path == "endpoints.transaction_classification.weird"
    end

    test "findings are sorted by endpoint name and report each violation" do
      exchange =
        tc_exchange("multi", %{
          "zSend" => %{"transactional" => false, "on_chain" => true},
          "aSend" => %{"transactional" => false, "on_chain" => true},
          "createOrder" => %{"transactional" => true, "on_chain" => false}
        })

      findings =
        ContractTest.check_transaction_classification_promoted_flags_consistent(
          exchange,
          @base_observed
        )

      assert Enum.map(findings, & &1.path) == [
               "endpoints.transaction_classification.aSend",
               "endpoints.transaction_classification.zSend"
             ]
    end

    test "no findings when transaction_classification is absent or nil" do
      assert ContractTest.check_transaction_classification_promoted_flags_consistent(
               %{"exchange" => %{"id" => "x"}},
               @base_observed
             ) == []

      assert ContractTest.check_transaction_classification_promoted_flags_consistent(
               tc_exchange("nilex", nil),
               @base_observed
             ) == []
    end
  end

  describe "Finding struct (Task 109)" do
    test "invariant builders emit %Finding{} structs, not bare maps" do
      exchange = %{
        "id" => "badex",
        "raw" => %{"describe" => %{"has" => %{"fetchOHLCV" => "__undefined"}}},
        "endpoints" => %{"unified" => %{"fetchOHLCV" => ["pubGetKlines"]}}
      }

      [finding] = ContractTest.check_unified_endpoints_claimed_in_has(exchange, @base_observed)
      assert %Finding{} = finding
    end

    test "@enforce_keys rejects construction missing a required key" do
      assert_raise ArgumentError, fn ->
        struct!(Finding, exchange: "x", invariant: "y", path: "z")
      end
    end

    test "Jason.encode of a Finding carries no __struct__ key" do
      finding = %Finding{exchange: "x", invariant: "y", path: "z", message: "m"}
      decoded = finding |> Jason.encode!() |> Jason.decode!()

      assert decoded == %{"exchange" => "x", "invariant" => "y", "path" => "z", "message" => "m"}
      refute Map.has_key?(decoded, "__struct__")
    end

    test "Enum.sort over findings is stable across the struct promotion" do
      findings = [
        %Finding{exchange: "b", invariant: "i", path: "p", message: "m"},
        %Finding{exchange: "a", invariant: "i", path: "p", message: "m"},
        %Finding{exchange: "a", invariant: "h", path: "p", message: "m"}
      ]

      sorted = Enum.sort_by(findings, &{&1.exchange, &1.invariant, &1.path})

      assert Enum.map(sorted, & &1.exchange) == ["a", "a", "b"]
      assert Enum.map(sorted, & &1.invariant) == ["h", "i", "i"]
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
          ["errors", "handle_errors", "error_code_fields"],
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

      {:ok, report} = ContractTest.run_all(output_dir: tmp, baseline_roots: ["response"], hierarchy_baseline: nil)

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

      # Findings serialize as plain string-keyed maps — no struct leakage.
      refute Map.has_key?(f1, "__struct__")

      # Baseline roots come from the committed safelist, not the corpus
      assert report["baseline"]["error_code_fields_roots"] == ["response"]
    end

    test "reports drifted override paths in output fixtures", %{tmp: tmp} do
      drifted =
        schema_conformant("hyperliquid", describe: %{"api" => %{"drifted" => %{}}}, authenticated_sections: ["drifted"])

      File.write!(Path.join(tmp, "hyperliquid.json"), Jason.encode!(drifted))
      File.write!(Path.join(tmp, "_manifest.json"), "{}")

      {:ok, report} = ContractTest.run_all(output_dir: tmp, baseline_roots: [], hierarchy_baseline: nil)

      assert report["summary"]["total_findings"] == 1
      assert report["summary"]["findings_by_invariant"]["override_paths_present_in_output"] == 1

      [finding] = report["findings"]
      assert finding["exchange"] == "hyperliquid"
      assert finding["invariant"] == "override_paths_present_in_output"
      assert finding["path"] == "/auth/authenticated_sections"
      assert finding["message"] =~ "drifted"
    end

    test "skips exchange_v4.json (schema copy) alongside per-exchange JSON", %{tmp: tmp} do
      File.write!(Path.join(tmp, "real.json"), Jason.encode!(%{"id" => "real"}))
      File.write!(Path.join(tmp, "exchange_v4.json"), Jason.encode!(%{"$schema" => "x"}))
      File.write!(Path.join(tmp, "_manifest.json"), "{}")

      {:ok, report} = ContractTest.run_all(output_dir: tmp, baseline_roots: [], hierarchy_baseline: nil)

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
      {:ok, report} = ContractTest.run_all(output_dir: tmp, baseline_roots: [], hierarchy_baseline: nil)
      out = Path.join(tmp, "report.json")
      assert :ok = ContractTest.write!(report, out)
      assert out |> File.read!() |> Jason.decode!() == report
    end

    test ~s|tier_scope defaults to "all" when opt not passed|, %{tmp: tmp} do
      File.write!(Path.join(tmp, "x.json"), Jason.encode!(%{"id" => "x"}))
      {:ok, report} = ContractTest.run_all(output_dir: tmp, baseline_roots: [], hierarchy_baseline: nil)
      assert report["tier_scope"] == "all"
    end

    test "tier_scope is stamped verbatim from opts", %{tmp: tmp} do
      File.write!(Path.join(tmp, "x.json"), Jason.encode!(%{"id" => "x"}))

      {:ok, report} =
        ContractTest.run_all(output_dir: tmp, baseline_roots: [], hierarchy_baseline: nil, tier_scope: ["tier1", "tier2"])

      assert report["tier_scope"] == ["tier1", "tier2"]
    end
  end
end

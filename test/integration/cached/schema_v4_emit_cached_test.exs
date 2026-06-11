defmodule CcxtExtract.Integration.Cached.SchemaV4EmitCachedTest do
  @moduledoc """
  Corpus-level assertion that the gated v4 emit path produces JSON that
  validates clean against `priv/schema/exchange_v4.json` for the three
  priority exchanges named in Task 130's acceptance criteria
  (`binance`, `deribit`, `okx`).

  Reads from `priv/discoveries/` (the committed extraction corpus) — does
  NOT re-run extraction.

  ## Corpus state — request_headers.json

  `request_headers.json` is a relatively recent (Task 73b, schema 3.1.0)
  discovery file. Older corpus snapshots may not have it. Task 90 added
  `rate_limit_costs.json`. Pipeline.extract raises when a required file is
  missing. The setup symlinks `priv/discoveries/` into a tmp dir and
  synthesizes minimal per-exchange JSON for any global `_.json` that is
  absent, unreadable, or a **broken symlink** (worktrees / partial corpus).
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Normalization.Market
  alias CcxtExtract.Paths
  alias CcxtExtract.Pipeline
  alias CcxtExtract.Test.StagedDiscoveries
  alias CcxtExtract.Validation

  @moduletag :integration

  @priority_scope MapSet.new(["binance", "deribit", "okx"])

  # Task 78b/78e — object-input parseOHLCV exchanges + bitmex parse8601 wrapper.
  # Separate scope so the binance/deribit/okx test (which asserts integer-locator
  # behavior) doesn't have to dispatch on a wider exchange set.
  @ohlcv_object_scope MapSet.new(["htx", "bitmex", "hyperliquid", "lighter"])

  setup do
    discoveries_dir = StagedDiscoveries.stage!(Paths.priv("discoveries"))
    on_exit(fn -> File.rm_rf!(discoveries_dir) end)
    {:ok, discoveries_dir: discoveries_dir}
  end

  describe "v4 emit round-trip" do
    test "build_exchange_data/3 produces v4 JSON that validates against exchange_v4.json for binance/deribit/okx",
         %{discoveries_dir: discoveries_dir} do
      {:ok, exchanges, _stats} =
        Pipeline.extract(
          discoveries_dir: discoveries_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-05-08T00:00:00Z",
          scope: @priority_scope
        )

      assert MapSet.new(Enum.map(exchanges, &get_in(&1, ["exchange", "id"]))) ==
               @priority_scope,
             "expected exactly the priority scope #{inspect(MapSet.to_list(@priority_scope))}, " <>
               "got #{inspect(Enum.map(exchanges, &get_in(&1, ["exchange", "id"])))} " <>
               "(have all of binance/deribit/okx been extracted?)"

      v4_root = Validation.build_schema_root()

      for exchange <- exchanges do
        id = get_in(exchange, ["exchange", "id"])

        assert exchange["schema_version"] == "4.0.0"

        # Top-level shape: producer-shaped sections gone, consumer-shaped present.
        refute Map.has_key?(exchange, "runtime"), "v4 emit must drop /runtime for #{id}"
        refute Map.has_key?(exchange, "structure"), "v4 emit must drop /structure for #{id}"

        for key <- ~w(endpoints auth errors rate_limits normalization markets testnet raw _provenance) do
          assert Map.has_key?(exchange, key), "missing top-level v4 key #{key} for #{id}"
        end

        # Task 90: rate_limits mirrors structure carriers — keys must exist even when null.
        rl = exchange["rate_limits"]
        assert Map.has_key?(rl, "per_endpoint_cost"), "missing rate_limits.per_endpoint_cost for #{id}"
        assert Map.has_key?(rl, "endpoint_cost_binding"), "missing rate_limits.endpoint_cost_binding for #{id}"

        # JSV strict validation against the v4 schema file.
        case Validation.validate_schema(exchange, v4_root) do
          :ok ->
            :ok

          {:error, findings} ->
            paths =
              findings
              |> Enum.take(5)
              |> Enum.map_join("\n  ", fn f -> "#{f["path"]}: #{f["message"]}" end)

            flunk("""
            v4 schema validation failed for #{id} (#{length(findings)} findings, first 5):
              #{paths}
            """)
        end

        # Task 129: normalization carrier is populated under v4 emit. The
        # digest must include every parse* method in the per-exchange
        # parse_methods.json entry; field_maps + response_envelopes are
        # scaffolds (Phase 12 populates them later).
        normalization = exchange["normalization"]
        assert is_map(normalization), "v4 emit must carry a normalization block for #{id}"

        for key <- ~w(parse_methods_digest field_maps response_envelopes) do
          assert Map.has_key?(normalization, key), "missing normalization.#{key} for #{id}"
        end

        assert normalization["field_maps"]["_unresolved_reason"] == "not_yet_derived",
               "Task 129 scaffold should mark field_maps unresolved until all parser types populate"

        # Task 83b: response_envelopes is derived per-fetcher when parse_dispatch
        # + fetch_methods.json bodies are present. Priority exchanges in this
        # scope have parse_dispatch → _unresolved_reason flips to nil and the
        # populated parser-type slots carry per-fetcher maps with the
        # {key, fallback_keys, default} contract. Exchanges with no
        # parse_dispatch stay on the stub ("not_yet_derived").
        response_envelopes = normalization["response_envelopes"]
        re_reason = response_envelopes["_unresolved_reason"]

        # Task 83b audit F5: closed-vocab includes "no_fetcher_dispatch" for
        # exchanges whose parse_dispatch contains only non-fetcher entries
        # (mutators / describe / transfer); the derivation ran and found nothing.
        assert re_reason in [nil, "not_yet_derived", "no_fetcher_dispatch"],
               "response_envelopes._unresolved_reason must be one of [nil, not_yet_derived, no_fetcher_dispatch] for #{id}, got #{inspect(re_reason)}"

        if id == "binance" do
          # binance's parseTrades is reached from multiple fetchers — the
          # N:1 case that motivated the per-fetcher map shape. Each entry
          # must carry either the {key, fallback_keys, default} triple or
          # an honest _unresolved_reason string.
          trade = response_envelopes["trade"]

          assert is_map(trade),
                 "binance has parse_dispatch for parseTrades → response_envelopes.trade must be a map, got #{inspect(trade)}"

          assert map_size(trade) >= 2,
                 "binance dispatches parseTrades from multiple fetchers — expected ≥2 keys, got #{inspect(Map.keys(trade))}"

          for {fetcher, entry} <- trade do
            assert String.starts_with?(fetcher, "fetch"),
                   "response_envelopes.trade key #{inspect(fetcher)} must be a fetch* name"

            assert is_map(entry),
                   "response_envelopes.trade[#{inspect(fetcher)}] must be a map"

            if Map.has_key?(entry, "_unresolved_reason") do
              assert is_binary(entry["_unresolved_reason"]),
                     "unresolved envelope entry must carry a string reason"
            else
              for key <- ~w(key fallback_keys default) do
                assert Map.has_key?(entry, key),
                       "populated envelope entry missing #{key} for binance.#{fetcher}"
              end

              assert is_list(entry["fallback_keys"]),
                     "fallback_keys must be a list for binance.#{fetcher}"
            end
          end
        end

        # Task 78: parseOHLCV field-map shape for the priority exchanges in
        # this test's scope. Indices are not asserted (they drift with
        # upstream CCXT bodies); coercion identity, guard kind, and
        # discriminator are stable.
        ohlcv = normalization["field_maps"]["ohlcv"]

        case id do
          "binance" ->
            assert is_map(ohlcv), "binance has a parseOHLCV override → field_maps.ohlcv populated"
            assert [branch] = ohlcv["branches"]
            assert branch["guard"]["kind"] == "always"
            assert branch["shape"] == "array"
            assert branch["_unresolved_reason"] == nil
            assert branch["field_map"]["timestamp"]["coercion"] == "safeInteger2"
            assert branch["field_map"]["timestamp"]["format"] == "ms"
            assert branch["field_map"]["volume"]["kind"] == "discriminated"
            assert branch["field_map"]["volume"]["discriminator"] == "market.inverse"

          "okx" ->
            # okx volumeIndex uses `(type === 'spot') ? 5 : 6` (Task 78f) —
            # now recognized as "market.spot" discriminator; volume slot populated.
            assert is_map(ohlcv)
            assert [branch] = ohlcv["branches"]
            assert branch["field_map"]["volume"]["kind"] == "discriminated"
            assert branch["field_map"]["volume"]["discriminator"] == "market.spot"
            assert branch["_unresolved_reason"] == nil
            assert branch["field_map"]["timestamp"]["coercion"] in ~w(safeInteger safeInteger2)

          "deribit" ->
            # deribit inherits parseOHLCV from a base class, so its own
            # parse_methods has no override — honest signal is null at
            # the carrier slot, not a fabricated shape.
            assert ohlcv == nil
        end
      end
    end

    test "Tasks 78b/78e — object-input parseOHLCV + parse8601 wrapper for htx/bitmex/hyperliquid/lighter",
         %{discoveries_dir: discoveries_dir} do
      # Tasks 78b/78e expand parseOHLCV extraction to object-input bodies
      # (string-keyed coercion calls) and bitmex's `parse8601(safeString(...))`
      # timestamp wrapper. Indices/keys are asserted from the closed-vocab
      # contract; the integer-index drift caveat from the binance/deribit/okx
      # test doesn't apply here because object-input keys are stable across
      # CCXT releases (they map to exchange wire-format field names).
      {:ok, exchanges, _stats} =
        Pipeline.extract(
          discoveries_dir: discoveries_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-05-08T00:00:00Z",
          scope: @ohlcv_object_scope,
          schema_target: 4
        )

      assert MapSet.new(Enum.map(exchanges, &get_in(&1, ["exchange", "id"]))) ==
               @ohlcv_object_scope,
             "expected exactly the 78b/78e scope #{inspect(MapSet.to_list(@ohlcv_object_scope))}"

      v4_root = Validation.build_schema_root()

      for exchange <- exchanges do
        id = get_in(exchange, ["exchange", "id"])

        case Validation.validate_schema(exchange, v4_root) do
          :ok ->
            :ok

          {:error, findings} ->
            paths =
              findings
              |> Enum.take(5)
              |> Enum.map_join("\n  ", fn f -> "#{f["path"]}: #{f["message"]}" end)

            flunk("""
            v4 schema validation failed for #{id} after object-input + parse8601 (#{length(findings)} findings, first 5):
              #{paths}
            """)
        end

        ohlcv = get_in(exchange, ["normalization", "field_maps", "ohlcv"])
        assert is_map(ohlcv), "#{id} parseOHLCV must populate field_maps.ohlcv"
        assert [branch] = ohlcv["branches"]

        assert branch["guard"]["input_shape"] == "object",
               "#{id} parseOHLCV body reads its input by string key → input_shape: object"

        case id do
          "hyperliquid" ->
            # hyperliquid: single-letter object keys (t/o/h/l/c/v), fully resolved.
            assert branch["_unresolved_reason"] == nil
            assert branch["field_map"]["timestamp"]["coercion"] == "safeInteger"
            assert branch["field_map"]["timestamp"]["format"] == "ms"
            assert branch["field_map"]["timestamp"]["key"] == "t"
            assert branch["field_map"]["timestamp"]["index"] == nil

            for {field, key} <- Enum.zip(~w(open high low close volume), ~w(o h l c v)) do
              assert branch["field_map"][field]["key"] == key
              assert branch["field_map"][field]["coercion"] == "safeNumber"
              assert branch["field_map"][field]["index"] == nil
            end

          "lighter" ->
            # lighter: byte-identical to hyperliquid for parseOHLCV — same single-letter
            # object keys, same coercions. Asserted separately to detect upstream drift.
            assert branch["_unresolved_reason"] == nil
            assert branch["field_map"]["timestamp"]["key"] == "t"
            assert branch["field_map"]["timestamp"]["coercion"] == "safeInteger"
            assert branch["field_map"]["volume"]["key"] == "v"
            assert branch["field_map"]["volume"]["coercion"] == "safeNumber"

          "htx" ->
            # htx: object-input, but timestamp uses `safeTimestamp` (s→ms vocab,
            # deferred to Task 78d). 5/6 slots resolve cleanly; timestamp is
            # honest-null with the closed-vocab rejection.
            assert branch["field_map"]["timestamp"] == nil
            assert branch["_unresolved_reason"] =~ "timestamp:non_safe_coercion:safeTimestamp"

            for field <- ~w(open high low close) do
              assert branch["field_map"][field]["coercion"] in ~w(safeNumber safeNumber2),
                     "htx OHLC slots use safeNumber-family"

              assert is_binary(branch["field_map"][field]["key"]),
                     "htx OHLC slots are object-keyed (string key)"

              assert branch["field_map"][field]["index"] == nil
            end

            # htx's volume key is "amount" — matches CCXT's wire-format mapping.
            assert branch["field_map"]["volume"]["key"] == "amount"

          "bitmex" ->
            # bitmex: parse8601 timestamp wrapper (Task 78e) + bare-Identifier
            # volume bound to `convertFromRawQuantity` (Task 78b Identifier-trace).
            assert branch["field_map"]["timestamp"]["coercion"] == "parse8601"
            assert branch["field_map"]["timestamp"]["format"] == "iso8601"
            assert branch["field_map"]["timestamp"]["key"] == "timestamp"
            assert branch["field_map"]["timestamp"]["index"] == nil

            assert branch["field_map"]["volume"] == nil
            assert branch["_unresolved_reason"] =~ "volume:non_safe_coercion:convertFromRawQuantity"

            for field <- ~w(open high low close) do
              assert branch["field_map"][field]["coercion"] == "safeNumber"
              assert is_binary(branch["field_map"][field]["key"])
            end
        end
      end
    end

    test "v3-shaped override pointer applies cleanly under --schema-target=4 (hyperliquid)",
         %{discoveries_dir: discoveries_dir} do
      # Regression: priv/overrides/hyperliquid.json carries the v3-shape
      # path /structure/authenticated_sections. Under --schema-target=4
      # the OverrideRegistry pointer translator rewrites it to
      # /auth/authenticated_sections so put_in/3 lands on the v4 tree
      # instead of synthesizing a rogue top-level `structure` key (which
      # would violate exchange_v4.json's additionalProperties: false).
      {:ok, [hyperliquid], _} =
        Pipeline.extract(
          discoveries_dir: discoveries_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-05-08T00:00:00Z",
          scope: MapSet.new(["hyperliquid"]),
          schema_target: 4
        )

      refute Map.has_key?(hyperliquid, "structure"),
             "v4 emit must not synthesize /structure when overrides apply"

      assert get_in(hyperliquid, ["auth", "authenticated_sections"]) == ["private"],
             "hyperliquid override must land on /auth/authenticated_sections under v4"

      assert hyperliquid["_provenance"]["/auth/authenticated_sections"] == "override",
             "override provenance must stamp the translated v4 pointer"

      v4_root = Validation.build_schema_root()
      assert Validation.validate_schema(hyperliquid, v4_root) == :ok
    end

    test "Task 74 — parseTicker field map for priority exchanges and kucoin unresolved",
         %{discoveries_dir: discoveries_dir} do
      # binance/okx/deribit all have a parseTicker override returning safeTicker —
      # field_maps.ticker must be populated with nil _unresolved_reason.
      # kucoin returns parseContractTicker — honest non-nil _unresolved_reason.
      ticker_scope = MapSet.new(["binance", "okx", "deribit", "kucoin"])

      {:ok, exchanges, _stats} =
        Pipeline.extract(
          discoveries_dir: discoveries_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-05-08T00:00:00Z",
          scope: ticker_scope,
          schema_target: 4
        )

      exchange_map = Map.new(exchanges, &{get_in(&1, ["exchange", "id"]), &1})

      for id <- ["binance", "okx", "deribit"] do
        ticker = get_in(exchange_map[id], ["normalization", "field_maps", "ticker"])
        assert is_map(ticker), "#{id} has parseTicker override → field_maps.ticker populated"
        assert ticker["_unresolved_reason"] == nil, "#{id} safeTicker return should parse cleanly"
        assert map_size(ticker["field_map"]) == 22, "#{id} ticker field_map must have all 22 unified fields"
        ts = ticker["field_map"]["timestamp"]
        assert is_map(ts), "#{id} timestamp slot must be populated"
        assert ts["format"] == "ms", "#{id} timestamp format must be ms"
        assert ts["coercion"] in ~w(safeInteger safeInteger2), "#{id} timestamp uses safeInteger family"
      end

      kucoin_ticker = get_in(exchange_map["kucoin"], ["normalization", "field_maps", "ticker"])
      assert is_map(kucoin_ticker), "kucoin ticker must be a map (unresolved, not nil)"
      assert is_binary(kucoin_ticker["_unresolved_reason"]), "kucoin must have non-nil _unresolved_reason"
      assert kucoin_ticker["_unresolved_reason"] =~ "non_safe_ticker_return"
    end

    test "Task 76 — parseTrade field map for priority exchanges and multi-payload detection",
         %{discoveries_dir: discoveries_dir} do
      # okx/deribit have a clean parseTrade returning safeTrade — field_maps.trade
      # populated with nil _unresolved_reason. binance/kraken have shape-discriminator
      # multi-payload bodies — honest `multi_payload_branching:<N>` _unresolved_reason.
      trade_scope = MapSet.new(["okx", "deribit", "binance", "kraken"])

      {:ok, exchanges, _stats} =
        Pipeline.extract(
          discoveries_dir: discoveries_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-05-08T00:00:00Z",
          scope: trade_scope,
          schema_target: 4
        )

      exchange_map = Map.new(exchanges, &{get_in(&1, ["exchange", "id"]), &1})

      # Schema validation guard — Task 76's new field_map shape (enum_map /
      # sub_field_map / unresolved_reason keys) must not regress v4 strict
      # validation. NormalizationStubValue is permissive (additionalProperties:
      # true), so this is a safety net, not a load-bearing assertion.
      v4_root = Validation.build_schema_root()

      for {id, exchange} <- exchange_map do
        case Validation.validate_schema(exchange, v4_root) do
          :ok ->
            :ok

          {:error, findings} ->
            paths =
              findings
              |> Enum.take(5)
              |> Enum.map_join("\n  ", fn f -> "#{f["path"]}: #{f["message"]}" end)

            flunk("v4 schema validation failed for #{id} after Task 76 trade derivation:\n  #{paths}")
        end
      end

      # okx: canonical safeTrade return — extraction-populated fields only (CCXT
      # derives cost/datetime/info/symbol downstream, so they're correctly null).
      okx_trade = get_in(exchange_map["okx"], ["normalization", "field_maps", "trade"])
      assert is_map(okx_trade), "okx parseTrade must populate field_maps.trade"
      assert okx_trade["_unresolved_reason"] == nil, "okx safeTrade return should parse cleanly"

      okx_populated =
        Enum.count(okx_trade["field_map"], fn {_k, v} -> is_map(v) and v["key"] != nil end)

      assert okx_populated >= 7,
             "okx trade field_map must populate ≥7 of 13 unified fields (got #{okx_populated})"

      # Spot-check key wire-key resolutions (proves coercion+key extraction works).
      assert okx_trade["field_map"]["timestamp"]["key"] == "ts"
      assert okx_trade["field_map"]["timestamp"]["format"] == "ms"
      assert okx_trade["field_map"]["id"]["key"] == "tradeId"
      assert okx_trade["field_map"]["price"]["key"] == "fillPx"

      # deribit: also a canonical safeTrade return
      deribit_trade = get_in(exchange_map["deribit"], ["normalization", "field_maps", "trade"])
      assert is_map(deribit_trade), "deribit parseTrade must populate field_maps.trade"
      assert deribit_trade["_unresolved_reason"] == nil, "deribit safeTrade return should parse cleanly"

      # binance and kraken: multi-payload bodies — honest unresolved tag
      for id <- ["binance", "kraken"] do
        trade = get_in(exchange_map[id], ["normalization", "field_maps", "trade"])
        assert is_map(trade), "#{id} trade must be a map (unresolved, not nil)"
        assert is_binary(trade["_unresolved_reason"]), "#{id} must have non-nil _unresolved_reason"

        assert trade["_unresolved_reason"] =~ "multi_payload_branching:",
               "#{id} must report multi_payload_branching:<N>, got #{inspect(trade["_unresolved_reason"])}"
      end
    end

    test "Task 75 — parseOrder field map for okx/deribit and multi-payload detection for kucoin/htx",
         %{discoveries_dir: discoveries_dir} do
      order_scope = MapSet.new(["okx", "deribit", "kucoin", "htx"])

      {:ok, exchanges, _stats} =
        Pipeline.extract(
          discoveries_dir: discoveries_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-05-08T00:00:00Z",
          scope: order_scope,
          schema_target: 4
        )

      exchange_map = Map.new(exchanges, &{get_in(&1, ["exchange", "id"]), &1})

      v4_root = Validation.build_schema_root()

      for {id, exchange} <- exchange_map do
        case Validation.validate_schema(exchange, v4_root) do
          :ok ->
            :ok

          {:error, findings} ->
            paths =
              findings
              |> Enum.take(5)
              |> Enum.map_join("\n  ", fn f -> "#{f["path"]}: #{f["message"]}" end)

            flunk("v4 schema validation failed for #{id} after Task 75 order derivation:\n  #{paths}")
        end
      end

      # okx: canonical safeOrder return — fields resolve cleanly
      okx_order = get_in(exchange_map["okx"], ["normalization", "field_maps", "order"])
      assert is_map(okx_order), "okx parseOrder must populate field_maps.order"
      assert okx_order["_unresolved_reason"] == nil, "okx safeOrder return should parse cleanly"

      okx_populated =
        Enum.count(okx_order["field_map"], fn {_k, v} -> is_map(v) and v["key"] != nil end)

      assert okx_populated >= 5,
             "okx order field_map must populate ≥5 of the unified fields (got #{okx_populated})"

      # deribit: also a canonical safeOrder return
      deribit_order = get_in(exchange_map["deribit"], ["normalization", "field_maps", "order"])
      assert is_map(deribit_order), "deribit parseOrder must populate field_maps.order"
      assert deribit_order["_unresolved_reason"] == nil

      # kucoin and htx: shape-discriminator branching — honest unresolved tag
      for id <- ["kucoin", "htx"] do
        order = get_in(exchange_map[id], ["normalization", "field_maps", "order"])
        assert is_map(order), "#{id} order must be a map (unresolved, not nil)"
        assert is_binary(order["_unresolved_reason"]), "#{id} must have non-nil _unresolved_reason"

        assert order["_unresolved_reason"] =~ "multi_payload_branching:",
               "#{id} must report multi_payload_branching:<N>, got #{inspect(order["_unresolved_reason"])}"
      end
    end

    test "Task 80 — parsePosition field map for okx/bybit and nil for binance (no override)",
         %{discoveries_dir: discoveries_dir} do
      position_scope = MapSet.new(["okx", "bybit", "binance"])

      {:ok, exchanges, _stats} =
        Pipeline.extract(
          discoveries_dir: discoveries_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-05-08T00:00:00Z",
          scope: position_scope,
          schema_target: 4
        )

      exchange_map = Map.new(exchanges, &{get_in(&1, ["exchange", "id"]), &1})

      v4_root = Validation.build_schema_root()

      for {id, exchange} <- exchange_map do
        case Validation.validate_schema(exchange, v4_root) do
          :ok ->
            :ok

          {:error, findings} ->
            paths =
              findings
              |> Enum.take(5)
              |> Enum.map_join("\n  ", fn f -> "#{f["path"]}: #{f["message"]}" end)

            flunk("v4 schema validation failed for #{id} after Task 80 position derivation:\n  #{paths}")
        end
      end

      # okx: canonical safePosition return — fields resolve cleanly
      okx_pos = get_in(exchange_map["okx"], ["normalization", "field_maps", "position"])
      assert is_map(okx_pos), "okx parsePosition must populate field_maps.position"
      assert okx_pos["_unresolved_reason"] == nil, "okx safePosition return should parse cleanly"

      okx_populated =
        Enum.count(okx_pos["field_map"], fn {_k, v} -> is_map(v) and v["key"] != nil end)

      assert okx_populated >= 5,
             "okx position field_map must populate ≥5 unified fields (got #{okx_populated})"

      # bybit: also a canonical safePosition return
      bybit_pos = get_in(exchange_map["bybit"], ["normalization", "field_maps", "position"])
      assert is_map(bybit_pos), "bybit parsePosition must populate field_maps.position"
      assert bybit_pos["_unresolved_reason"] == nil

      # binance: no parsePosition override — honest nil at the carrier slot
      binance_pos = get_in(exchange_map["binance"], ["normalization", "field_maps", "position"])
      assert binance_pos == nil, "binance has no parsePosition override → position slot must be nil"
    end

    test "Task 81 — parseTransaction field map for exchanges with a direct-return body",
         %{discoveries_dir: discoveries_dir} do
      # binance has a parseTransaction returning a TSAsExpression-wrapped
      # ObjectExpression — field_maps.transaction must be populated with nil
      # _unresolved_reason. deribit also has a parseTransaction override.
      # okx is included to confirm it also resolves cleanly.
      tx_scope = MapSet.new(["binance", "deribit", "okx"])

      {:ok, exchanges, _stats} =
        Pipeline.extract(
          discoveries_dir: discoveries_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-05-08T00:00:00Z",
          scope: tx_scope,
          schema_target: 4
        )

      exchange_map = Map.new(exchanges, &{get_in(&1, ["exchange", "id"]), &1})

      v4_root = Validation.build_schema_root()

      for {id, exchange} <- exchange_map do
        case Validation.validate_schema(exchange, v4_root) do
          :ok ->
            :ok

          {:error, findings} ->
            paths =
              findings
              |> Enum.take(5)
              |> Enum.map_join("\n  ", fn f -> "#{f["path"]}: #{f["message"]}" end)

            flunk("v4 schema validation failed for #{id} after Task 81 transaction derivation:\n  #{paths}")
        end
      end

      for id <- ["binance", "deribit", "okx"] do
        tx = get_in(exchange_map[id], ["normalization", "field_maps", "transaction"])
        # All three have a parseTransaction override — must be populated.
        assert is_map(tx), "#{id} has parseTransaction override → field_maps.transaction populated"
        assert map_size(tx["field_map"]) == 18, "#{id} transaction field_map must have all 18 unified fields"
      end
    end

    test "Task 82 — parseDepositAddress field map for exchanges with a direct-return body",
         %{discoveries_dir: discoveries_dir} do
      # okx/binance have a parseDepositAddress override returning an ObjectExpression
      # — field_maps.deposit_address must be populated.
      # deribit has no parseDepositAddress override — honest nil.
      da_scope = MapSet.new(["binance", "okx", "deribit"])

      {:ok, exchanges, _stats} =
        Pipeline.extract(
          discoveries_dir: discoveries_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-05-08T00:00:00Z",
          scope: da_scope,
          schema_target: 4
        )

      exchange_map = Map.new(exchanges, &{get_in(&1, ["exchange", "id"]), &1})

      v4_root = Validation.build_schema_root()

      for {id, exchange} <- exchange_map do
        case Validation.validate_schema(exchange, v4_root) do
          :ok ->
            :ok

          {:error, findings} ->
            paths =
              findings
              |> Enum.take(5)
              |> Enum.map_join("\n  ", fn f -> "#{f["path"]}: #{f["message"]}" end)

            flunk("v4 schema validation failed for #{id} after Task 82 depositAddress derivation:\n  #{paths}")
        end
      end

      for id <- ["binance", "okx"] do
        da = get_in(exchange_map[id], ["normalization", "field_maps", "deposit_address"])
        assert is_map(da), "#{id} has parseDepositAddress override → field_maps.deposit_address populated"
        assert map_size(da["field_map"]) == 5, "#{id} depositAddress field_map must have all 5 unified fields"
      end

      deribit_da = get_in(exchange_map["deribit"], ["normalization", "field_maps", "deposit_address"])
      assert deribit_da == nil, "deribit has no parseDepositAddress override → honest nil"
    end

    test "Task 77 — parseBalance field map for exchanges with safeBalance return",
         %{discoveries_dir: discoveries_dir} do
      # aftermath and alpaca have parseBalance returning safeBalance(Identifier)
      # with direct account field assignments — field_maps.balance must be
      # populated with nil _unresolved_reason.
      # deribit/bybit/kraken also have safeBalance returns but their assignments
      # are nested deeper (loop bodies) — they still resolve to nil _unresolved_reason.
      balance_scope = MapSet.new(["aftermath", "deribit", "bybit"])

      {:ok, exchanges, _stats} =
        Pipeline.extract(
          discoveries_dir: discoveries_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-05-08T00:00:00Z",
          scope: balance_scope,
          schema_target: 4
        )

      exchange_map = Map.new(exchanges, &{get_in(&1, ["exchange", "id"]), &1})

      for id <- ["aftermath", "deribit", "bybit"] do
        balance = get_in(exchange_map[id], ["normalization", "field_maps", "balance"])
        assert is_map(balance), "#{id} has parseBalance override → field_maps.balance populated"
        assert balance["_unresolved_reason"] == nil, "#{id} safeBalance return should parse cleanly"
        assert map_size(balance["field_map"]) == 7, "#{id} balance field_map must have all 7 unified fields"
      end

      # aftermath has direct account field assignments — spot-check specific slots
      aftermath_balance = get_in(exchange_map["aftermath"], ["normalization", "field_maps", "balance"])
      assert is_map(aftermath_balance["field_map"]["free"]), "aftermath free slot populated"
      assert aftermath_balance["field_map"]["free"]["key"] == "free"
      assert aftermath_balance["field_map"]["free"]["coercion"] in ~w(safeString safeString2 safeNumber safeNumber2)

      # structurally-null fields are always nil
      for id <- ["aftermath", "deribit", "bybit"] do
        balance = get_in(exchange_map[id], ["normalization", "field_maps", "balance"])
        assert balance["field_map"]["info"] == nil, "#{id} balance info must be nil (pass-through)"
        assert balance["field_map"]["datetime"] == nil, "#{id} balance datetime must be nil (iso8601 derived)"
      end
    end

    test "Task 79 — parseMarket field map for exchanges with ObjectExpression return",
         %{discoveries_dir: discoveries_dir} do
      # aftermath returns safeMarketStructure({...}) with many direct safe calls.
      # hyperliquid returns safeMarketStructure({...}) but uses Identifiers for most
      # fields — slots resolve via binding lookup or emit nil.
      # binance returns an Identifier directly — unresolved.
      market_scope = MapSet.new(["aftermath", "hyperliquid", "binance"])

      {:ok, exchanges, _stats} =
        Pipeline.extract(
          discoveries_dir: discoveries_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-05-08T00:00:00Z",
          scope: market_scope,
          schema_target: 4
        )

      exchange_map = Map.new(exchanges, &{get_in(&1, ["exchange", "id"]), &1})

      # aftermath: safeMarketStructure + ObjectExpression with direct safe calls
      aftermath_market = get_in(exchange_map["aftermath"], ["normalization", "field_maps", "market"])
      assert is_map(aftermath_market), "aftermath has parseMarket → field_maps.market populated"
      assert aftermath_market["_unresolved_reason"] == nil, "aftermath should parse cleanly"

      assert map_size(aftermath_market["field_map"]) == length(Market.unified_fields()),
             "aftermath market field_map must have all unified fields"

      # spot-check a few resolved slots
      assert is_map(aftermath_market["field_map"]["id"]), "aftermath id slot populated"
      assert aftermath_market["field_map"]["id"]["key"] == "id"
      assert aftermath_market["field_map"]["id"]["coercion"] == "safeString"

      # structurally-null fields must be nil regardless of what's in the object
      assert aftermath_market["field_map"]["symbol"] == nil,
             "aftermath market symbol must be nil (structurally null)"

      assert aftermath_market["field_map"]["info"] == nil,
             "aftermath market info must be nil (structurally null)"

      # hyperliquid: safeMarketStructure return — resolves cleanly even if most slots are nil
      hyper_market = get_in(exchange_map["hyperliquid"], ["normalization", "field_maps", "market"])
      assert is_map(hyper_market), "hyperliquid has parseMarket → field_maps.market populated"
      assert hyper_market["_unresolved_reason"] == nil, "hyperliquid should parse cleanly"
      assert map_size(hyper_market["field_map"]) == length(Market.unified_fields())

      # binance parseMarket returns an Identifier (not an ObjectExpression) — unresolved
      binance_market = get_in(exchange_map["binance"], ["normalization", "field_maps", "market"])
      assert is_map(binance_market), "binance parseMarket must be a map (unresolved, not nil)"

      assert is_binary(binance_market["_unresolved_reason"]),
             "binance parseMarket must have non-nil _unresolved_reason"
    end
  end
end

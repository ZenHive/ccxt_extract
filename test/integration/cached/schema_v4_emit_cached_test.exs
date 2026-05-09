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
  discovery file. Older corpus snapshots may not have it. Pipeline.extract
  raises when it's missing. To keep this test robust against that single
  pre-existing corpus gap, the setup builds a tmp_dir that mirrors
  `priv/discoveries/` via symlinks AND synthesizes a minimal
  `request_headers.json` (one entry per known exchange, all empty
  records) when the canonical corpus lacks one.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Paths
  alias CcxtExtract.Pipeline
  alias CcxtExtract.Validation

  @moduletag :integration

  @priority_scope MapSet.new(["binance", "deribit", "okx"])

  setup do
    discoveries_dir = stage_discoveries!(Paths.priv("discoveries"))
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
          scope: @priority_scope,
          schema_target: 4
        )

      assert MapSet.new(Enum.map(exchanges, &get_in(&1, ["exchange", "id"]))) ==
               @priority_scope,
             "expected exactly the priority scope #{inspect(MapSet.to_list(@priority_scope))}, " <>
               "got #{inspect(Enum.map(exchanges, &get_in(&1, ["exchange", "id"])))} " <>
               "(have all of binance/deribit/okx been extracted?)"

      v4_root = Validation.build_schema_root(4)

      for exchange <- exchanges do
        id = get_in(exchange, ["exchange", "id"])

        assert exchange["schema_version"] == "4.0.0-pre"

        # Top-level shape: producer-shaped sections gone, consumer-shaped present.
        refute Map.has_key?(exchange, "runtime"), "v4 emit must drop /runtime for #{id}"
        refute Map.has_key?(exchange, "structure"), "v4 emit must drop /structure for #{id}"

        for key <- ~w(endpoints auth errors rate_limits normalization markets testnet raw _provenance) do
          assert Map.has_key?(exchange, key), "missing top-level v4 key #{key} for #{id}"
        end

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

        assert normalization["response_envelopes"]["_unresolved_reason"] == "not_yet_derived",
               "Task 129 scaffold should mark response_envelopes unresolved for #{id}"

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
            # okx's volumeIndex is gated on `(type === 'spot') ? 5 : 6`,
            # not market.inverse — per the closed-vocab honesty rule, the
            # volume slot emits null with a branch-level reason. The
            # other 5 slots (timestamp + OHLC) populate normally.
            assert is_map(ohlcv)
            assert [branch] = ohlcv["branches"]
            assert branch["field_map"]["volume"] == nil
            assert branch["_unresolved_reason"] =~ "non_inverse_discriminator"
            assert branch["field_map"]["timestamp"]["coercion"] in ~w(safeInteger safeInteger2)

          "deribit" ->
            # deribit inherits parseOHLCV from a base class, so its own
            # parse_methods has no override — honest signal is null at
            # the carrier slot, not a fabricated shape.
            assert ohlcv == nil
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

      v4_root = Validation.build_schema_root(4)
      assert Validation.validate_schema(hyperliquid, v4_root) == :ok
    end

    test "v3 emit (default) is byte-identical with or without explicit --schema-target=3 for binance",
         %{discoveries_dir: discoveries_dir} do
      # Equivalence guard: the only thing that changes between
      # `schema_target: 3` (explicit) and an omitted opt is one keyword.
      # Output must be identical down to the byte.
      {:ok, [explicit], _} =
        Pipeline.extract(
          discoveries_dir: discoveries_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-05-08T00:00:00Z",
          scope: MapSet.new(["binance"]),
          schema_target: 3
        )

      {:ok, [implicit], _} =
        Pipeline.extract(
          discoveries_dir: discoveries_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-05-08T00:00:00Z",
          scope: MapSet.new(["binance"])
        )

      assert explicit == implicit
      assert explicit["schema_version"] == CcxtExtract.Schema.schema_version()
      assert Map.has_key?(explicit, "runtime")
      assert Map.has_key?(explicit, "structure")
    end
  end

  # Mirror priv/discoveries/ into a tmp dir using symlinks so we don't
  # copy the multi-MB corpus, then synthesize request_headers.json if the
  # canonical corpus lacks it (older snapshots predate Task 73b).
  defp stage_discoveries!(source_dir) do
    tmp = Path.join(System.tmp_dir!(), "ccxt_extract_v4_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    for entry <- File.ls!(source_dir) do
      src = Path.join(source_dir, entry)
      dst = Path.join(tmp, entry)
      :ok = File.ln_s(src, dst)
    end

    exchanges_path = Path.join(tmp, "exchanges.json")

    ids =
      case CcxtExtract.JsonIO.read_json(exchanges_path) do
        {:ok, %{"exchanges" => entries}} -> Enum.map(entries, & &1["id"])
        _ -> []
      end

    request_headers_path = Path.join(tmp, "request_headers.json")

    if !File.exists?(request_headers_path) do
      # Synthesize a minimal request_headers.json indexed by every
      # exchange in the corpus's exchanges.json. Each entry carries the
      # schema's empty record so build_runtime_section/1 has something
      # to read; pipeline behavior is identical to the corpus-fresh case
      # for the priority scope we care about.
      synthetic = %{
        "exchanges" =>
          Enum.map(ids, fn id ->
            %{"id" => id, "request_headers" => CcxtExtract.RequestHeaders.empty_record()}
          end)
      }

      File.write!(request_headers_path, Jason.encode!(synthetic, pretty: true))
    end

    rate_limit_buckets_path = Path.join(tmp, "rate_limit_buckets.json")

    if !File.exists?(rate_limit_buckets_path) do
      # Same synthesis pattern as request_headers above (Task 89). Each
      # entry carries the empty bucket wrapper so the pipeline has a
      # legitimate `rate_limit_buckets` key to thread into the structure
      # section without forcing a real QuickBEAM probe.
      synthetic = %{
        "exchanges" =>
          Enum.map(ids, fn id ->
            %{"id" => id, "rate_limit_buckets" => CcxtExtract.RateLimitBuckets.empty_record()}
          end)
      }

      File.write!(rate_limit_buckets_path, Jason.encode!(synthetic, pretty: true))
    end

    tmp
  end
end

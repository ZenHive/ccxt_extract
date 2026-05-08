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

      assert length(exchanges) == 3,
             "expected 3 priority exchanges, got #{length(exchanges)} (have all of binance/deribit/okx been extracted?)"

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
      end
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
      assert explicit["schema_version"] == "3.1.0"
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

    request_headers_path = Path.join(tmp, "request_headers.json")

    if !File.exists?(request_headers_path) do
      # Synthesize a minimal request_headers.json indexed by every
      # exchange in the corpus's exchanges.json. Each entry carries the
      # schema's empty record so build_runtime_section/1 has something
      # to read; pipeline behavior is identical to the corpus-fresh case
      # for the priority scope we care about.
      exchanges_path = Path.join(tmp, "exchanges.json")

      ids =
        case CcxtExtract.JsonIO.read_json(exchanges_path) do
          {:ok, %{"exchanges" => entries}} -> Enum.map(entries, & &1["id"])
          _ -> []
        end

      synthetic = %{
        "exchanges" =>
          Enum.map(ids, fn id ->
            %{"id" => id, "request_headers" => CcxtExtract.RequestHeaders.empty_record()}
          end)
      }

      File.write!(request_headers_path, Jason.encode!(synthetic, pretty: true))
    end

    tmp
  end
end

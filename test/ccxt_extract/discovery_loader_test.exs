defmodule CcxtExtract.DiscoveryLoaderTest do
  @moduledoc """
  Isolation tests for DiscoveryLoader — exercise the loader's contract
  (shape of returned data, integrity stats) against synthetic fixtures
  under `tmp_dir`. No QuickBEAM/OXC, no real priv/discoveries data.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.DiscoveryLoader

  # read_json/1 tests live in test/ccxt_extract/json_io_test.exs since the
  # helper was promoted to CcxtExtract.JsonIO (REFACTOR.md Item 8).

  describe "load_all!/2 shape" do
    @tag :tmp_dir
    test "returns full data map with all expected keys", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: [],
        markets_succeeded: []
      )

      exchanges_json = %{"exchanges" => [%{"id" => "fakex"}]}
      data = DiscoveryLoader.load_all!(tmp_dir, exchanges_json)

      expected_keys = ~w(exchanges describe load_markets classes methods_rest
                        methods_ws sign_methods handle_errors parse_methods
                        ws_methods interface_signatures pagination
                        unified_endpoints url_templates overrides
                        canonical_has_keys missing_files missing_entries
                        corrupt_entries orphan_entries id_mismatch_entries)a

      for key <- expected_keys do
        assert Map.has_key?(data, key), "expected key #{inspect(key)} in load_all! result"
      end
    end
  end

  describe "load_all!/2 integrity stats" do
    @tag :tmp_dir
    test "missing describe/_manifest.json records a missing_files entry", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir, describe_exchanges: [], markets_succeeded: [])
      File.rm!(Path.join(tmp_dir, "describe/_manifest.json"))

      exchanges_json = %{"exchanges" => [%{"id" => "fakex"}]}
      data = DiscoveryLoader.load_all!(tmp_dir, exchanges_json)

      assert "describe/_manifest.json" in data.missing_files
    end

    @tag :tmp_dir
    test "missing per-exchange describe file records missing_entries", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: ["fakex"],
        markets_succeeded: []
      )

      # Manifest lists fakex but the per-exchange file is absent.

      exchanges_json = %{"exchanges" => [%{"id" => "fakex"}]}
      data = DiscoveryLoader.load_all!(tmp_dir, exchanges_json)

      assert "describe/fakex.json" in data.missing_entries
    end

    @tag :tmp_dir
    test "corrupt JSON raises for a global file", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir, describe_exchanges: [], markets_succeeded: [])
      File.write!(Path.join(tmp_dir, "handle_errors.json"), "{not json")

      exchanges_json = %{"exchanges" => [%{"id" => "fakex"}]}

      assert_raise RuntimeError, ~r/Corrupt discovery artifact/, fn ->
        DiscoveryLoader.load_all!(tmp_dir, exchanges_json)
      end
    end

    @tag :tmp_dir
    test "id mismatch in per-exchange describe file is recorded", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: ["fakex"],
        markets_succeeded: []
      )

      # Write a describe file whose top-level id disagrees with the manifest.
      write_json(Path.join(tmp_dir, "describe/fakex.json"), %{
        "id" => "other",
        "describe" => %{"id" => "other"}
      })

      exchanges_json = %{"exchanges" => [%{"id" => "fakex"}]}
      data = DiscoveryLoader.load_all!(tmp_dir, exchanges_json)

      assert Enum.any?(data.id_mismatch_entries, &String.contains?(&1, "describe/fakex.json"))
    end
  end

  describe "canonical_has_keys derivation" do
    @tag :tmp_dir
    test "computes union of has keys across loaded describe entries", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: ["fakex"],
        markets_succeeded: []
      )

      write_json(Path.join(tmp_dir, "describe/fakex.json"), %{
        "id" => "fakex",
        "describe" => %{
          "id" => "fakex",
          "has" => %{"fetchTicker" => true, "fetchOHLCV" => false}
        }
      })

      exchanges_json = %{"exchanges" => [%{"id" => "fakex"}]}
      data = DiscoveryLoader.load_all!(tmp_dir, exchanges_json)

      assert MapSet.member?(data.canonical_has_keys, "fetchTicker")
      assert MapSet.member?(data.canonical_has_keys, "fetchOHLCV")
    end
  end

  # --- Fixture helpers (adapted from test/ccxt_extract/pipeline_test.exs:1104-1155) ---

  defp write_minimal_fixtures(dir, opts) do
    describe_exchanges = Keyword.get(opts, :describe_exchanges, [])
    markets_succeeded = Keyword.get(opts, :markets_succeeded, [])

    all_exchanges = [
      %{
        "id" => "fakex",
        "name" => "Fake Exchange",
        "certified" => false,
        "pro" => false,
        "version" => nil,
        "country" => [],
        "alias" => false,
        "referral" => nil
      }
    ]

    write_json(Path.join(dir, "exchanges.json"), %{"exchanges" => all_exchanges})
    write_json(Path.join(dir, "class_hierarchy.json"), %{"classes" => []})

    empty_global = %{"exchanges" => []}
    write_json(Path.join(dir, "methods_rest.json"), empty_global)
    write_json(Path.join(dir, "methods_ws.json"), empty_global)
    write_json(Path.join(dir, "sign_methods.json"), empty_global)
    write_json(Path.join(dir, "handle_errors.json"), empty_global)
    write_json(Path.join(dir, "parse_methods.json"), empty_global)
    write_json(Path.join(dir, "ws_methods.json"), empty_global)
    write_json(Path.join(dir, "interface_signatures.json"), empty_global)
    write_json(Path.join(dir, "pagination.json"), empty_global)
    write_json(Path.join(dir, "unified_endpoints.json"), empty_global)
    write_json(Path.join(dir, "url_templates.json"), empty_global)
    write_json(Path.join(dir, "overrides.json"), empty_global)

    write_json(Path.join(dir, "describe/_manifest.json"), %{"exchanges" => describe_exchanges})

    write_json(Path.join(dir, "load_markets/_manifest.json"), %{
      "succeeded" => markets_succeeded
    })
  end

  defp write_json(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data))
  end
end

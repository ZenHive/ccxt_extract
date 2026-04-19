defmodule CcxtExtract.Integration.Cached.SchemaCachedTest do
  @moduledoc """
  Cached integration tests for Schema — validates that the schema fits
  real discovery data from priv/discoveries/.
  No QuickBEAM/OXC needed.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Schema

  @moduletag :integration
  @moduletag timeout: 30_000

  @fixtures_dir CcxtExtract.Paths.discoveries()
  @base_opts [ccxt_version: "4.5.45", extracted_at: "2026-03-30T12:00:00Z"]

  # --- Fixture loaders ---

  defp load_json(path) do
    path |> File.read!() |> Jason.decode!()
  end

  defp load_exchanges do
    load_json(Path.join(@fixtures_dir, "exchanges.json"))["exchanges"]
  end

  defp load_exchange_meta(id) do
    Enum.find(load_exchanges(), &(&1["id"] == id))
  end

  defp load_describe(id) do
    path = Path.join([@fixtures_dir, "describe", "#{id}.json"])
    if File.exists?(path), do: load_json(path)["describe"]
  end

  defp load_markets(id) do
    path = Path.join([@fixtures_dir, "load_markets", "#{id}.json"])

    if File.exists?(path) do
      data = load_json(path)
      %{"market_count" => data["market_count"], "markets" => data["markets"]}
    end
  end

  defp load_class_hierarchy do
    load_json(Path.join(@fixtures_dir, "class_hierarchy.json"))
  end

  defp load_methods(type) do
    filename = "methods_#{type}.json"
    load_json(Path.join(@fixtures_dir, filename))["exchanges"]
  end

  defp load_sign_methods do
    load_json(Path.join(@fixtures_dir, "sign_methods.json"))["exchanges"]
  end

  defp load_handle_errors do
    load_json(Path.join(@fixtures_dir, "handle_errors.json"))["exchanges"]
  end

  defp load_overrides do
    load_json(Path.join(@fixtures_dir, "overrides.json"))["exchanges"]
  end

  # Finds an entry by id in a list of exchange maps
  defp find_by_id(list, id), do: Enum.find(list, &(&1["id"] == id))

  # Assembles class_info for a given exchange from the class hierarchy fixture
  defp build_class_info(id, hierarchy) do
    classes = hierarchy["classes"]
    rest = Enum.find(classes, &(&1["id"] == id and &1["type"] == "rest"))
    ws = Enum.find(classes, &(&1["id"] == id and &1["type"] == "ws"))

    if rest do
      %{"rest" => strip_class_fields(rest), "ws" => strip_class_fields(ws)}
    end
  end

  # Pass through class entry as-is (schema now matches raw data shape)
  defp strip_class_fields(nil), do: nil
  defp strip_class_fields(entry), do: entry

  # Assembles method inventory for a given exchange
  defp build_methods(id, rest_methods, ws_methods) do
    rest = find_by_id(rest_methods, id)
    ws = find_by_id(ws_methods, id)

    if rest do
      %{"rest" => rest["methods"], "ws" => if(ws, do: ws["methods"])}
    end
  end

  # Assembles handle_errors section
  defp build_handle_errors(entry) do
    if entry && entry["handle_errors"] do
      method = entry["handle_errors"]

      %{
        "method" => method,
        "exceptions" => entry["exceptions"],
        "http_exceptions" => entry["http_exceptions"],
        "error_code_fields" => CcxtExtract.ErrorCodeFields.derive(method),
        "throw_dispatches" => CcxtExtract.ThrowDispatches.derive(method)
      }
    end
  end

  # Assembles overrides section — groups REST/WS entries like the pipeline does
  defp build_overrides(entries) do
    case entries do
      [] ->
        nil

      entries ->
        rest = Enum.find(entries, &String.starts_with?(&1["parent_key"] || "", "rest:"))
        ws = Enum.find(entries, &String.starts_with?(&1["parent_key"] || "", "ws:"))
        primary = rest || ws

        %{
          "extends" => primary["extends"],
          "rest" => format_override_entry(rest),
          "ws" => format_override_entry(ws)
        }
    end
  end

  defp format_override_entry(nil), do: nil

  defp format_override_entry(entry) do
    %{
      "parent_key" => entry["parent_key"],
      "overridden" => entry["overrides"] || %{},
      "new_methods" => entry["new_methods"] || %{},
      "inherited" => entry["inherited_methods"] || []
    }
  end

  # Builds a complete per-exchange output from fixture data. Schema 3.0.0
  # (Task 117): runtime.markets replaced by runtime.symbols_index; structure
  # drops parse_methods / ws_methods (extractors still populate discovery
  # files — this test just no longer threads them into the emitted JSON).
  defp build_from_fixtures(id) do
    meta = load_exchange_meta(id)
    hierarchy = load_class_hierarchy()
    rest_methods = load_methods("rest")
    ws_methods = load_methods("ws")
    sign_entry = find_by_id(load_sign_methods(), id)
    he_entry = find_by_id(load_handle_errors(), id)
    ov_entries = Enum.filter(load_overrides(), &(&1["id"] == id))

    runtime = %{
      "describe" => load_describe(id),
      "symbols_index" => CcxtExtract.SymbolsIndex.derive(load_markets(id))
    }

    structure = %{
      "class_info" => build_class_info(id, hierarchy),
      "methods" => build_methods(id, rest_methods, ws_methods),
      "sign_method" => if(sign_entry, do: sign_entry["sign"]),
      "handle_errors" => build_handle_errors(he_entry),
      "overrides" => build_overrides(ov_entries)
    }

    Schema.build_exchange(meta, runtime, structure, @base_opts)
  end

  # --- Tests ---

  describe "binance (full exchange, pro, not derived from non-Exchange)" do
    setup do
      %{exchange: build_from_fixtures("binance")}
    end

    test "validates successfully", %{exchange: exchange} do
      assert :ok = Schema.validate(exchange)
    end

    test "has describe data", %{exchange: exchange} do
      describe = exchange["runtime"]["describe"]
      assert is_map(describe)
      assert is_map(describe["has"])
      assert is_map(describe["api"])
    end

    test "has symbols_index", %{exchange: exchange} do
      idx = exchange["runtime"]["symbols_index"]
      assert is_map(idx)
      assert map_size(idx) > 0

      for {_sym, entry} <- idx do
        assert entry |> Map.keys() |> Enum.sort() == ["spot", "swap"]
        assert is_boolean(entry["spot"])
        assert is_boolean(entry["swap"])
      end
    end

    test "has sign method AST", %{exchange: exchange} do
      sign = exchange["structure"]["sign_method"]
      assert is_map(sign)
      assert sign["body"]["type"] == "BlockStatement"
      assert is_list(sign["params"])
    end

    # parse_methods + ws_methods are no longer emitted (schema 3.0.0, Task 117).
    # The extractors still run and discovery files exist — see
    # test/integration/cached/parse_methods_cached_test.exs and
    # test/integration/cached/ws_methods_cached_test.exs.
    test "structure no longer carries parse_methods or ws_methods", %{exchange: exchange} do
      refute Map.has_key?(exchange["structure"], "parse_methods")
      refute Map.has_key?(exchange["structure"], "ws_methods")
    end

    test "has class info with REST and WS", %{exchange: exchange} do
      ci = exchange["structure"]["class_info"]
      assert is_map(ci["rest"])
      assert is_map(ci["ws"])
      assert ci["rest"]["node_key"] == "rest:binance"
    end

    test "has method inventory with REST and WS", %{exchange: exchange} do
      methods = exchange["structure"]["methods"]
      assert is_list(methods["rest"])
      assert methods["rest"] != []
      assert is_list(methods["ws"])
    end
  end

  describe "binanceus (derived exchange with overrides)" do
    setup do
      %{exchange: build_from_fixtures("binanceus")}
    end

    test "validates successfully", %{exchange: exchange} do
      assert :ok = Schema.validate(exchange)
    end

    test "has overrides section", %{exchange: exchange} do
      ov = exchange["structure"]["overrides"]
      assert is_map(ov)
      assert ov["extends"] == "binance"
      assert is_map(ov["rest"]) or is_map(ov["ws"])
    end
  end

  describe "deribit (standalone, not derived)" do
    setup do
      %{exchange: build_from_fixtures("deribit")}
    end

    test "validates successfully", %{exchange: exchange} do
      assert :ok = Schema.validate(exchange)
    end

    test "has no overrides (root exchange)", %{exchange: exchange} do
      # deribit extends Exchange directly — may or may not appear in overrides
      # depending on whether it's classified as derived
      ov = exchange["structure"]["overrides"]
      assert is_nil(ov) or is_map(ov)
    end
  end

  describe "throw_dispatches regressions" do
    # whitebit regression removed: whitebit is an unclassified-tier exchange,
    # and per CLAUDE.md tier-based scoping the project does not commit to
    # derivation correctness on unclassified exchanges. Reinstate once
    # whitebit is promoted to a priority tier.

    # bithumb regression removed: bithumb is not in the current tier_scope
    # extraction and fixtures do not include it. Reinstate (and regenerate
    # fixtures) once bithumb is promoted to a priority tier.

    test "binance keeps all dispatches and exposes message_lookup explicitly" do
      exchange = build_from_fixtures("binance")
      dispatches = exchange["structure"]["handle_errors"]["throw_dispatches"]

      assert length(dispatches) == 8
      assert Enum.all?(dispatches, &Map.has_key?(&1, "message_lookup"))
      assert Enum.any?(dispatches, &(&1["lookup"]["field"] == "msg"))
      assert Enum.any?(dispatches, &(&1["lookup"]["field"] == "code"))
    end
  end

  describe "schema structure consistency across reference exchanges" do
    @tier1 ~w(binance bybit okx deribit coinbaseexchange)

    for exchange_id <- @tier1 do
      @exchange_id exchange_id

      test "#{@exchange_id} produces valid schema output" do
        exchange = build_from_fixtures(@exchange_id)
        assert :ok = Schema.validate(exchange)

        assert exchange["schema_version"] == Schema.schema_version()
        assert exchange["exchange"]["id"] == @exchange_id
        assert is_map(exchange["runtime"])
        assert is_map(exchange["structure"])
      end
    end
  end
end

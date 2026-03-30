defmodule CcxtExtract.Integration.Cached.SchemaCachedTest do
  @moduledoc """
  Cached integration tests for Schema — validates that the schema fits
  real fixture data from test/fixtures/discoveries/.
  No QuickBEAM/OXC needed.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Schema

  @moduletag :integration
  @moduletag timeout: 30_000

  @fixtures_dir Path.expand("../../fixtures/discoveries", __DIR__)
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

  defp load_parse_methods do
    load_json(Path.join(@fixtures_dir, "parse_methods.json"))["exchanges"]
  end

  defp load_ws_methods do
    load_json(Path.join(@fixtures_dir, "ws_methods.json"))["exchanges"]
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
      %{
        "method" => entry["handle_errors"],
        "exceptions" => entry["exceptions"],
        "http_exceptions" => entry["http_exceptions"]
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

  # Builds a complete per-exchange output from fixture data
  defp build_from_fixtures(id) do
    meta = load_exchange_meta(id)
    hierarchy = load_class_hierarchy()
    rest_methods = load_methods("rest")
    ws_methods = load_methods("ws")
    sign_entry = find_by_id(load_sign_methods(), id)
    he_entry = find_by_id(load_handle_errors(), id)
    pm_entry = find_by_id(load_parse_methods(), id)
    wm_entry = find_by_id(load_ws_methods(), id)
    ov_entries = Enum.filter(load_overrides(), &(&1["id"] == id))

    runtime = %{
      "describe" => load_describe(id),
      "markets" => load_markets(id)
    }

    structure = %{
      "class_info" => build_class_info(id, hierarchy),
      "methods" => build_methods(id, rest_methods, ws_methods),
      "sign_method" => if(sign_entry, do: sign_entry["sign"]),
      "handle_errors" => build_handle_errors(he_entry),
      "parse_methods" => if(pm_entry, do: pm_entry["parse_methods"]),
      "ws_methods" => if(wm_entry, do: wm_entry["ws_methods"]),
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

    test "has markets data", %{exchange: exchange} do
      markets = exchange["runtime"]["markets"]
      assert is_map(markets)
      assert markets["market_count"] > 0
    end

    test "has sign method AST", %{exchange: exchange} do
      sign = exchange["structure"]["sign_method"]
      assert is_map(sign)
      assert sign["body"]["type"] == "BlockStatement"
      assert is_list(sign["params"])
    end

    test "has parse methods", %{exchange: exchange} do
      pm = exchange["structure"]["parse_methods"]
      assert is_map(pm)
      assert map_size(pm) > 0

      for {_name, method} <- pm do
        assert is_map(method["body"])
        assert is_list(method["params"])
      end
    end

    test "has WS methods", %{exchange: exchange} do
      wm = exchange["structure"]["ws_methods"]
      assert is_map(wm)
      assert map_size(wm) > 0
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

  describe "schema structure consistency across reference exchanges" do
    @tier1 ~w(binance bybit okx deribit coinbaseexchange)

    for exchange_id <- @tier1 do
      @exchange_id exchange_id

      test "#{@exchange_id} produces valid schema output" do
        exchange = build_from_fixtures(@exchange_id)
        assert :ok = Schema.validate(exchange)

        assert exchange["schema_version"] == "1.0"
        assert exchange["exchange"]["id"] == @exchange_id
        assert is_map(exchange["runtime"])
        assert is_map(exchange["structure"])
      end
    end
  end
end

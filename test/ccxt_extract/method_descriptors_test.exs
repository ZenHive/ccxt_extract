defmodule CcxtExtract.MethodDescriptorsTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.MethodDescriptors
  alias Mix.Tasks.CcxtExtract.MethodDescriptors, as: MethodDescriptorsTask

  doctest MethodDescriptors

  # A representative exchange class exercising: a fully-documented unified
  # method, a unified method with no JSDoc, a sync parser (excluded), a static
  # method (excluded), and a private `_`-prefixed method (excluded).
  @source """
  export default class binance extends Exchange {
      /**
       * @method
       * @name binance#fetchOrder
       * @description fetches information on an order made by the user
       * @see https://example.com/docs
       * @param {string} id the order id
       * @param {string} [symbol] unified symbol of the market
       * @param {object} [params] extra parameters specific to the api endpoint
       * @returns {object} an [order structure]{@link https://docs/#order}
       * @throws {OrderNotFound} when the order does not exist
       * @throws {ArgumentsRequired} when symbol is missing
       */
      async fetchOrder (id: string, symbol: Str = undefined, params = {}): Promise<Order> {
          return this.privateGetOrder (id);
      }
      async createOrder (symbol: string, type: string): Promise<Order> {
          return this.privatePostOrder (symbol);
      }
      parseOrder (order, market: Market = undefined): Order {
          return order;
      }
      static getDefault (): Promise<void> {
          return undefined;
      }
      async _internalHelper (): Promise<void> {
          return undefined;
      }
  }
  """

  defp parse(source \\ @source) do
    {:ok, ast} = OXC.parse(source, "binance.ts")
    {ast, source}
  end

  defp class_members(ast) do
    Enum.find(ast.body, &(&1.type == :export_default_declaration)).declaration.body.body
  end

  defp method(ast, name) do
    Enum.find(class_members(ast), &(get_in(&1, [:key, :name]) == name))
  end

  describe "unified_method?/1" do
    setup do
      {ast, _source} = parse()
      {:ok, ast: ast}
    end

    test "true for a public async Promise-returning method", %{ast: ast} do
      assert MethodDescriptors.unified_method?(method(ast, "fetchOrder"))
      assert MethodDescriptors.unified_method?(method(ast, "createOrder"))
    end

    test "false for a sync parser returning a non-Promise type", %{ast: ast} do
      refute MethodDescriptors.unified_method?(method(ast, "parseOrder"))
    end

    test "false for a static method even when it returns a Promise", %{ast: ast} do
      refute MethodDescriptors.unified_method?(method(ast, "getDefault"))
    end

    test "false for a private `_`-prefixed method", %{ast: ast} do
      refute MethodDescriptors.unified_method?(method(ast, "_internalHelper"))
    end

    test "false for a non-method node" do
      refute MethodDescriptors.unified_method?(%{type: :property_definition})
    end
  end

  describe "build_descriptor/2 — TS signature half" do
    test "extracts ordered params with name, type, optional flag, and default" do
      {ast, source} = parse()
      desc = MethodDescriptors.build_descriptor(method(ast, "fetchOrder"), source)

      assert desc["name"] == "fetchOrder"
      assert desc["async"] == true
      assert desc["signature"]["return_type"] == "Promise<Order>"

      params = desc["signature"]["params"]
      assert Enum.map(params, & &1["name"]) == ["id", "symbol", "params"]

      assert Enum.at(params, 0) == %{
               "name" => "id",
               "type" => "string",
               "optional" => false,
               "default" => nil
             }

      # `symbol: Str = undefined` — typed assignment pattern carries its raw default.
      assert Enum.at(params, 1) == %{
               "name" => "symbol",
               "type" => "Str",
               "optional" => true,
               "default" => "undefined"
             }

      # `params = {}` — untyped assignment pattern, raw default sliced from source.
      assert Enum.at(params, 2) == %{
               "name" => "params",
               "type" => nil,
               "optional" => true,
               "default" => "{}"
             }
    end

    test "source is the byte-for-byte method-definition slice" do
      {ast, source} = parse()
      m = method(ast, "fetchOrder")
      desc = MethodDescriptors.build_descriptor(m, source)

      assert desc["source"] == binary_part(source, m.start, m.end - m.start)
      assert String.starts_with?(desc["source"], "async fetchOrder (")
      assert String.ends_with?(desc["source"], "}")
      # The slice is the method only — the preceding JSDoc is NOT part of source.
      refute String.contains?(desc["source"], "@description")
    end
  end

  describe "build_descriptor/2 — JSDoc overlay half" do
    test "fuses description, per-param prose, returns, and throws" do
      {ast, source} = parse()
      desc = MethodDescriptors.build_descriptor(method(ast, "fetchOrder"), source)

      assert desc["description"] == "fetches information on an order made by the user"
      assert desc["unresolved_reason"] == nil

      assert desc["params_doc"] == %{
               "id" => "the order id",
               "symbol" => "unified symbol of the market",
               "params" => "extra parameters specific to the api endpoint"
             }

      assert desc["returns"]["type"] == "object"
      assert desc["returns"]["description"] =~ "order structure"

      assert desc["errors"] == [
               %{"class" => "OrderNotFound", "description" => "when the order does not exist"},
               %{"class" => "ArgumentsRequired", "description" => "when symbol is missing"}
             ]
    end

    test "honest partial descriptor when the method has no JSDoc" do
      {ast, source} = parse()
      desc = MethodDescriptors.build_descriptor(method(ast, "createOrder"), source)

      # Signature half is still fully populated.
      assert Enum.map(desc["signature"]["params"], & &1["name"]) == ["symbol", "type"]
      assert desc["signature"]["return_type"] == "Promise<Order>"

      # Overlay half is honestly absent.
      assert desc["description"] == nil
      assert desc["params_doc"] == nil
      assert desc["returns"] == nil
      assert desc["errors"] == nil
      assert desc["unresolved_reason"] == "no_jsdoc"
    end
  end

  describe "parse_jsdoc/1" do
    test "nil block yields the honest no_jsdoc overlay" do
      assert MethodDescriptors.parse_jsdoc(nil) == %{
               description: nil,
               params_doc: nil,
               returns: nil,
               errors: nil,
               unresolved_reason: "no_jsdoc"
             }
    end

    test "present block without @throws yields [] errors, not nil" do
      block = "/**\n * @description does a thing\n * @returns {int} a count\n */"
      overlay = MethodDescriptors.parse_jsdoc(block)

      assert overlay.description == "does a thing"
      assert overlay.errors == []
      assert overlay.unresolved_reason == nil
    end

    test "multi-line description is joined across continuation lines" do
      block = "/**\n * @description first part\n * second part\n * @param {x} a y\n */"
      overlay = MethodDescriptors.parse_jsdoc(block)

      assert overlay.description == "first part second part"
      assert overlay.params_doc == %{"a" => "y"}
    end

    test "a bare @description with no prose collapses to nil" do
      block = "/**\n * @description\n */"
      assert MethodDescriptors.parse_jsdoc(block).description == nil
    end

    test "@param with a default in brackets keeps just the name" do
      block = "/**\n * @param {int} [limit=50] the max count\n */"
      assert MethodDescriptors.parse_jsdoc(block).params_doc == %{"limit" => "the max count"}
    end
  end

  describe "extract_from_ast/3" do
    test "emits one descriptor per unified method, sorted by name" do
      {ast, source} = parse()
      entry = MethodDescriptors.extract_from_ast(ast, source, "binance.ts")

      assert entry["id"] == "binance"
      assert entry["class_name"] == "binance"
      assert entry["file"] == "binance.ts"
      assert entry["descriptor_count"] == 2
      assert Enum.map(entry["descriptors"], & &1["name"]) == ["createOrder", "fetchOrder"]
    end

    test "returns nil when there is no exported class" do
      {:ok, ast} = OXC.parse("const x = 1;", "not_a_class.ts")
      assert MethodDescriptors.extract_from_ast(ast, "const x = 1;", "not_a_class.ts") == nil
    end

    test "falls back to filename when the class is anonymous" do
      source = "export default class extends Exchange {\n  async go (): Promise<void> { return undefined; }\n}\n"
      {:ok, ast} = OXC.parse(source, "anon.ts")
      entry = MethodDescriptors.extract_from_ast(ast, source, "anon.ts")

      assert entry["id"] == "anon"
      assert entry["class_name"] == nil
      assert entry["descriptor_count"] == 1
    end
  end

  describe "write_stats/1" do
    test "counts exchanges with descriptors and the grand total" do
      exchanges = [
        %{"descriptor_count" => 3},
        %{"descriptor_count" => 0},
        %{"descriptor_count" => 5}
      ]

      assert MethodDescriptors.write_stats(exchanges) == %{
               "with_descriptors" => 2,
               "total_descriptors" => 8
             }
    end
  end

  describe "write!/2 + JSON round-trip" do
    test "writes a merge-safe aggregate that round-trips through JSON" do
      {ast, source} = parse()
      entry = MethodDescriptors.extract_from_ast(ast, source, "binance.ts")
      path = Path.join(System.tmp_dir!(), "method_descriptors_#{System.unique_integer([:positive])}.json")
      on_exit(fn -> File.rm_rf!(path) end)

      assert :ok =
               MethodDescriptors.write!([entry],
                 output_path: path,
                 extracted_at: "2026-01-01T00:00:00Z"
               )

      decoded = path |> File.read!() |> Jason.decode!()

      assert decoded["count"] == 1
      assert decoded["provenance"] == "raw"
      assert decoded["with_descriptors"] == 1
      assert decoded["total_descriptors"] == 2
      assert decoded["extracted_at"] == "2026-01-01T00:00:00Z"

      [exchange] = decoded["exchanges"]
      assert exchange["id"] == "binance"
      descriptor = Enum.find(exchange["descriptors"], &(&1["name"] == "fetchOrder"))
      assert descriptor["errors"] |> hd() |> Map.fetch!("class") == "OrderNotFound"
    end
  end

  describe "Mix.Tasks.CcxtExtract.MethodDescriptors CLI validation" do
    test "uses TaskScope for argument parsing" do
      source = File.read!("lib/mix/tasks/ccxt_extract.method_descriptors.ex")

      assert source =~ "TaskScope.parse_and_resolve!(args)"
      refute source =~ "OptionParser."
    end

    test "rejects unknown switches" do
      assert_raise Mix.Error, ~r/Unknown option/, fn ->
        MethodDescriptorsTask.run(["--typo"])
      end
    end

    test "rejects positional arguments" do
      assert_raise Mix.Error, ~r/Unexpected argument/, fn ->
        MethodDescriptorsTask.run(["binance"])
      end
    end
  end
end

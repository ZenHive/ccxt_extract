defmodule CcxtExtract.ErrorClassHierarchyTest do
  @moduledoc """
  Unit tests for `CcxtExtract.ErrorClassHierarchy`.

  Drives synthetic OXC AST shapes through `from_ast/1` so the assembly
  logic (default-export resolution + tree walk + flat_parents + ancestors)
  is exercised without depending on the real CCXT source.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.ErrorClassHierarchy

  describe "from_ast/1 — happy path" do
    test "extracts a single-root linear chain" do
      ast =
        wrap_export_const(
          "errorHierarchy",
          obj([
            {"BaseError",
             obj([
               {"ExchangeError",
                obj([
                  {"AuthenticationError", obj([])}
                ])}
             ])}
          ])
        )

      assert {:ok, record} = ErrorClassHierarchy.from_ast(ast)

      assert record["tree"] == %{
               "BaseError" => %{
                 "ExchangeError" => %{
                   "AuthenticationError" => %{}
                 }
               }
             }

      assert record["flat_parents"] == %{
               "BaseError" => nil,
               "ExchangeError" => "BaseError",
               "AuthenticationError" => "ExchangeError"
             }

      assert record["ancestors"]["BaseError"] == []
      assert record["ancestors"]["ExchangeError"] == ["BaseError"]
      assert record["ancestors"]["AuthenticationError"] == ["ExchangeError", "BaseError"]
    end

    test "extracts a branching tree (multiple children at each level)" do
      ast =
        wrap_export_const(
          "errorHierarchy",
          obj([
            {"BaseError",
             obj([
               {"ExchangeError", obj([{"AuthenticationError", obj([])}])},
               {"NetworkError", obj([{"RequestTimeout", obj([])}])}
             ])}
          ])
        )

      assert {:ok, record} = ErrorClassHierarchy.from_ast(ast)

      assert record["flat_parents"]["AuthenticationError"] == "ExchangeError"
      assert record["flat_parents"]["RequestTimeout"] == "NetworkError"
      assert record["ancestors"]["AuthenticationError"] == ["ExchangeError", "BaseError"]
      assert record["ancestors"]["RequestTimeout"] == ["NetworkError", "BaseError"]
    end

    test "ancestor chain is parent-first, root-last" do
      ast =
        wrap_export_const(
          "errorHierarchy",
          obj([
            {"BaseError",
             obj([
               {"L1",
                obj([
                  {"L2",
                   obj([
                     {"L3",
                      obj([
                        {"L4", obj([])}
                      ])}
                   ])}
                ])}
             ])}
          ])
        )

      assert {:ok, record} = ErrorClassHierarchy.from_ast(ast)
      assert record["ancestors"]["L4"] == ["L3", "L2", "L1", "BaseError"]
    end

    test "leaf classes get empty children maps" do
      ast =
        wrap_export_const(
          "errorHierarchy",
          obj([
            {"BaseError",
             obj([
               {"Leaf", obj([])}
             ])}
          ])
        )

      assert {:ok, record} = ErrorClassHierarchy.from_ast(ast)
      assert record["tree"]["BaseError"]["Leaf"] == %{}
    end

    test "supports literal export — `export default { ... }` shape" do
      # Future-proofing: if CCXT ever inlines the literal at export site
      # instead of the current `const X = ...; export default X` shape,
      # the extractor still resolves it without touching the resolver.
      ast = %{
        body: [
          %{
            type: :export_default_declaration,
            declaration:
              obj([
                {"BaseError", obj([{"ExchangeError", obj([])}])}
              ])
          }
        ]
      }

      assert {:ok, record} = ErrorClassHierarchy.from_ast(ast)
      assert record["flat_parents"] == %{"BaseError" => nil, "ExchangeError" => "BaseError"}
    end
  end

  describe "from_ast/1 — error paths (Honesty Rule)" do
    test "returns :no_default_export when there is no default export" do
      ast = %{body: [%{type: :variable_declaration, declarations: []}]}
      assert {:error, :no_default_export} = ErrorClassHierarchy.from_ast(ast)
    end

    test "returns :unexpected_default_export_shape when default-export is neither identifier nor object" do
      ast = %{
        body: [
          %{
            type: :export_default_declaration,
            declaration: %{type: :literal, value: 42}
          }
        ]
      }

      assert {:error, :unexpected_default_export_shape} = ErrorClassHierarchy.from_ast(ast)
    end

    test "returns :identifier_not_found when default-export refers to an undefined identifier" do
      ast = %{
        body: [
          %{
            type: :export_default_declaration,
            declaration: %{type: :identifier, name: "missingThing"}
          }
        ]
      }

      assert {:error, {:identifier_not_found, "missingThing"}} = ErrorClassHierarchy.from_ast(ast)
    end

    test "skips variable declarations whose init is not an ObjectExpression" do
      # `const errorHierarchy = makeTree();` — call expression, not literal
      ast = %{
        body: [
          %{
            type: :variable_declaration,
            declarations: [
              %{
                id: %{type: :identifier, name: "errorHierarchy"},
                init: %{type: :call_expression, callee: %{name: "makeTree"}, arguments: []}
              }
            ]
          },
          %{
            type: :export_default_declaration,
            declaration: %{type: :identifier, name: "errorHierarchy"}
          }
        ]
      }

      assert {:error, {:identifier_not_found, "errorHierarchy"}} = ErrorClassHierarchy.from_ast(ast)
    end
  end

  describe "required_keys/0" do
    test "returns the three contractually-required keys" do
      assert ErrorClassHierarchy.required_keys() == ["tree", "flat_parents", "ancestors"]
    end
  end

  describe "write!/2" do
    @tmp_dir Path.join(System.tmp_dir!(), "ccxt_extract_error_class_hierarchy_write_test")

    setup do
      File.rm_rf!(@tmp_dir)
      File.mkdir_p!(@tmp_dir)
      on_exit(fn -> File.rm_rf!(@tmp_dir) end)
      {:ok, tmp: @tmp_dir}
    end

    test "writes the record plus envelope (extracted_at, tier_scope, class_count)", %{tmp: tmp} do
      path = Path.join(tmp, "error_class_hierarchy.json")

      record = %{
        "tree" => %{"BaseError" => %{"ExchangeError" => %{}}},
        "flat_parents" => %{"BaseError" => nil, "ExchangeError" => "BaseError"},
        "ancestors" => %{"BaseError" => [], "ExchangeError" => ["BaseError"]}
      }

      assert :ok = ErrorClassHierarchy.write!(record, output_path: path)
      decoded = path |> File.read!() |> Jason.decode!()

      assert decoded["tree"] == record["tree"]
      assert decoded["flat_parents"] == record["flat_parents"]
      assert decoded["ancestors"] == record["ancestors"]
      assert decoded["class_count"] == 2
      assert decoded["tier_scope"] == "all"
      assert is_binary(decoded["extracted_at"])
    end

    test "stamps caller-supplied tier_scope override", %{tmp: tmp} do
      path = Path.join(tmp, "error_class_hierarchy.json")

      record = %{
        "tree" => %{"BaseError" => %{}},
        "flat_parents" => %{"BaseError" => nil},
        "ancestors" => %{"BaseError" => []}
      }

      assert :ok = ErrorClassHierarchy.write!(record, output_path: path, tier_scope: ["tier1"])
      decoded = path |> File.read!() |> Jason.decode!()
      assert decoded["tier_scope"] == ["tier1"]
    end
  end

  describe "extract/0 — real source" do
    @tag :extraction
    test "extracts the full hierarchy from priv/ccxt/ts/src/base/errorHierarchy.ts" do
      assert {:ok, record} = ErrorClassHierarchy.extract()

      assert is_map(record["tree"])
      assert is_map(record["flat_parents"])
      assert is_map(record["ancestors"])

      # BaseError is the single root.
      assert record["flat_parents"]["BaseError"] == nil
      roots = for {class, nil} <- record["flat_parents"], do: class
      assert Enum.sort(roots) == ["BaseError"]
      assert record["ancestors"]["BaseError"] == []

      # AccountNotEnabled is the documented deepest leaf at depth 4.
      assert record["ancestors"]["AccountNotEnabled"] == [
               "PermissionDenied",
               "AuthenticationError",
               "ExchangeError",
               "BaseError"
             ]

      # Spot-check a few well-known mid-tree classes.
      assert record["flat_parents"]["RateLimitExceeded"] == "NetworkError"
      assert record["flat_parents"]["AuthenticationError"] == "ExchangeError"

      # Floor count — concrete CCXT release at extraction time had 41,
      # future bumps shouldn't break the test.
      assert map_size(record["flat_parents"]) >= 40
    end
  end

  # --- AST Builders ---

  defp wrap_export_const(name, object_expr) do
    %{
      body: [
        %{
          type: :variable_declaration,
          declarations: [
            %{
              id: %{type: :identifier, name: name},
              init: object_expr
            }
          ]
        },
        %{
          type: :export_default_declaration,
          declaration: %{type: :identifier, name: name}
        }
      ]
    }
  end

  defp obj(entries) do
    %{
      type: :object_expression,
      properties:
        Enum.map(entries, fn {key, value} ->
          %{
            type: :property,
            key: %{type: :literal, value: key},
            value: value
          }
        end)
    }
  end
end

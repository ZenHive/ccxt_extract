defmodule CcxtExtract.InterfaceSignaturesTest do
  @moduledoc """
  Tests for InterfaceSignatures extraction from abstract TypeScript files.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.InterfaceSignatures

  describe "extract_from_ast/2" do
    test "extracts signatures from a crafted interface AST" do
      ast = %{
        body: [
          %{
            type: "TSInterfaceDeclaration",
            id: %{name: "Exchange"},
            body: %{
              body: [
                %{
                  type: "TSMethodSignature",
                  key: %{name: "publicGetTicker"},
                  params: [
                    %{
                      type: "Identifier",
                      name: "params",
                      optional: true,
                      typeAnnotation: %{
                        type: "TSTypeAnnotation",
                        typeAnnotation: %{type: "TSTypeLiteral", members: []}
                      },
                      decorators: []
                    }
                  ],
                  returnType: %{
                    type: "TSTypeAnnotation",
                    typeAnnotation: %{
                      type: "TSTypeReference",
                      typeName: %{
                        name: "Promise",
                        type: "Identifier",
                        optional: false,
                        typeAnnotation: nil,
                        decorators: []
                      },
                      typeArguments: %{
                        type: "TSTypeParameterInstantiation",
                        params: [
                          %{
                            type: "TSTypeReference",
                            typeName: %{
                              name: "implicitReturnType",
                              type: "Identifier",
                              optional: false,
                              typeAnnotation: nil,
                              decorators: []
                            },
                            typeArguments: nil
                          }
                        ]
                      }
                    }
                  }
                },
                %{
                  type: "TSMethodSignature",
                  key: %{name: "privatePostOrder"},
                  params: [],
                  returnType: nil
                }
              ]
            }
          }
        ]
      }

      result = InterfaceSignatures.extract_from_ast(ast, "testex.ts")

      assert result["id"] == "testex"
      assert result["file"] == "testex.ts"
      assert result["interface_name"] == "Exchange"
      assert result["interface_signature_count"] == 2

      ticker = result["interface_signatures"]["publicGetTicker"]
      assert ticker["name"] == "publicGetTicker"
      assert ticker["params"] == [%{"name" => "params", "type" => "typeliteral"}]
      assert ticker["return_type"] == "Promise<implicitReturnType>"

      order = result["interface_signatures"]["privatePostOrder"]
      assert order["name"] == "privatePostOrder"
      assert order["params"] == []
      assert order["return_type"] == nil
    end

    test "extracts signatures from alias interface (non-Exchange name)" do
      ast = %{
        body: [
          %{
            type: "TSInterfaceDeclaration",
            id: %{name: "binance"},
            body: %{
              body: [
                %{
                  type: "TSMethodSignature",
                  key: %{name: "publicGetTicker"},
                  params: [],
                  returnType: nil
                }
              ]
            }
          }
        ]
      }

      result = InterfaceSignatures.extract_from_ast(ast, "binanceus.ts")
      assert result["id"] == "binanceus"
      assert result["interface_name"] == "binance"
      assert result["interface_signature_count"] == 1
      assert Map.has_key?(result["interface_signatures"], "publicGetTicker")
    end

    test "returns nil when no TSInterfaceDeclaration found" do
      ast = %{body: [%{type: "ClassDeclaration", id: %{name: "Foo"}}]}
      assert InterfaceSignatures.extract_from_ast(ast, "foo.ts") == nil
    end
  end

  describe "extract_signature/1" do
    test "extracts name, params, and return_type" do
      member = %{
        type: "TSMethodSignature",
        key: %{name: "fetchBalance"},
        params: [
          %{
            type: "Identifier",
            name: "code",
            optional: false,
            typeAnnotation: %{
              type: "TSTypeAnnotation",
              typeAnnotation: %{
                type: "TSTypeReference",
                typeName: %{name: "string", type: "Identifier", optional: false, typeAnnotation: nil, decorators: []},
                typeArguments: nil
              }
            },
            decorators: []
          }
        ],
        returnType: %{
          type: "TSTypeAnnotation",
          typeAnnotation: %{
            type: "TSTypeReference",
            typeName: %{name: "Promise", type: "Identifier", optional: false, typeAnnotation: nil, decorators: []},
            typeArguments: %{
              type: "TSTypeParameterInstantiation",
              params: [
                %{
                  type: "TSTypeReference",
                  typeName: %{name: "Balances", type: "Identifier", optional: false, typeAnnotation: nil, decorators: []},
                  typeArguments: nil
                }
              ]
            }
          }
        }
      }

      result = InterfaceSignatures.extract_signature(member)

      assert result == %{
               "name" => "fetchBalance",
               "params" => [%{"name" => "code", "type" => "string"}],
               "return_type" => "Promise<Balances>"
             }
    end
  end

  describe "parse_file/1" do
    @tag :extraction
    test "parses a real abstract file" do
      path = Path.join(CcxtExtract.Paths.ts_src(), "abstract/hyperliquid.ts")

      if File.exists?(path) do
        assert {:ok, result} = InterfaceSignatures.parse_file(path)
        assert result["id"] == "hyperliquid"
        assert result["interface_signature_count"] == 2
        assert Map.has_key?(result["interface_signatures"], "publicPostInfo")
      else
        flunk("CCXT abstract source not found at #{path}. Run `mix ccxt_extract.setup` first.")
      end
    end
  end

  describe "extract/0" do
    @tag :extraction
    test "extracts all abstract files" do
      {:ok, exchanges, stats} = InterfaceSignatures.extract()

      assert exchanges != []
      assert stats.errors == []
      assert stats.skipped == [], "Expected no skipped files, got: #{inspect(stats.skipped)}"

      # All entries have required keys
      for exchange <- exchanges do
        assert is_binary(exchange["id"])
        assert is_binary(exchange["file"])
        assert is_integer(exchange["interface_signature_count"])
        assert is_map(exchange["interface_signatures"])
      end

      # Spot-check binance — must exist if CCXT source is present
      binance = Enum.find(exchanges, &(&1["id"] == "binance"))
      assert binance, "binance should exist in extracted exchanges"
      assert binance["interface_signature_count"] > 100

      # Check a signature has expected structure
      {_name, sig} = Enum.at(binance["interface_signatures"], 0)
      assert is_binary(sig["name"])
      assert is_list(sig["params"])
      assert Map.has_key?(sig, "return_type")
    end
  end
end

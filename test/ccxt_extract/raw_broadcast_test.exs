defmodule CcxtExtract.RawBroadcastTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.RawBroadcast

  # `this.<name>(...)` call expression node (atom-keyed, OXC shape).
  defp this_call(name) do
    %{
      type: :call_expression,
      callee: %{
        type: :member_expression,
        object: %{type: :this_expression},
        property: %{type: :identifier, name: name}
      },
      arguments: []
    }
  end

  # A method_definition whose body invokes each name in `this_calls`.
  defp method(name, async, this_calls) do
    %{
      type: :method_definition,
      key: %{name: name},
      value: %{
        async: async,
        params: [],
        body: %{
          type: :function_body,
          body: Enum.map(this_calls, &%{type: :expression_statement, expression: this_call(&1)})
        }
      }
    }
  end

  defp import_decl(source) do
    %{type: :import_declaration, source: %{value: source}}
  end

  defp ast(class_name, members, imports \\ []) do
    %{
      body:
        imports ++
          [
            %{
              type: :export_default_declaration,
              declaration: %{
                type: :class_declaration,
                id: %{name: class_name},
                superClass: %{name: "Exchange"},
                body: %{body: members}
              }
            }
          ]
    }
  end

  describe "extract_from_ast/2 — direct broadcast helpers" do
    test "promotes an async write method that calls a broadcast helper" do
      ast =
        ast("hyperliquid", [
          method("createOrder", true, ["signL1Action"]),
          method("signL1Action", false, [])
        ])

      result = RawBroadcast.extract_from_ast(ast, "hyperliquid.ts")

      assert result["id"] == "hyperliquid"
      assert result["broadcast_methods"] == %{"createOrder" => ["signL1Action"]}
    end

    test "drops fetch* reads that sign (authentication, not broadcast)" do
      # paradex's fetchBalance signs a starknet challenge to READ private state
      ast =
        ast("paradex", [
          method("fetchBalance", true, ["starknetSign"]),
          method("createOrder", true, ["starknetSign"])
        ])

      result = RawBroadcast.extract_from_ast(ast, "paradex.ts")

      assert Map.has_key?(result["broadcast_methods"], "createOrder")
      refute Map.has_key?(result["broadcast_methods"], "fetchBalance")
    end

    test "drops the synchronous signing primitive itself" do
      ast =
        ast("hyperliquid", [
          method("withdraw", true, ["signUserSignedAction"]),
          # primitive is sync — must not be promoted as an endpoint
          method("signUserSignedAction", false, ["signL1Action"])
        ])

      result = RawBroadcast.extract_from_ast(ast, "hyperliquid.ts")

      assert Map.has_key?(result["broadcast_methods"], "withdraw")
      refute Map.has_key?(result["broadcast_methods"], "signUserSignedAction")
    end
  end

  describe "extract_from_ast/2 — transitive reach" do
    test "credits an endpoint that signs through an intermediate helper" do
      ast =
        ast("hyperliquid", [
          method("withdraw", true, ["buildWithdrawSig"]),
          method("buildWithdrawSig", false, ["signUserSignedAction"]),
          method("signUserSignedAction", false, [])
        ])

      result = RawBroadcast.extract_from_ast(ast, "hyperliquid.ts")

      assert result["broadcast_methods"] == %{"withdraw" => ["signUserSignedAction"]}
    end

    test "terminates on a call cycle without diverging" do
      ast =
        ast("dex", [
          method("a", true, ["b", "signEIP712"]),
          method("b", false, ["a"])
        ])

      result = RawBroadcast.extract_from_ast(ast, "dex.ts")
      assert result["broadcast_methods"] == %{"a" => ["signEIP712"]}
    end
  end

  describe "extract_from_ast/2 — corroborating signals" do
    test "records signing-library imports and the eip712 builder flag" do
      # Real CCXT vendors crypto into static_dependencies/noble-curves (hyphen);
      # noble-hashes (keccak) is intentionally excluded as it is hashing, not
      # signing. `ethers` proves the forward-looking marker still matches if a
      # future CCXT imports it directly.
      ast =
        ast(
          "grvt",
          [method("createOrder", true, ["hashTypedData"])],
          [
            import_decl("ethers"),
            import_decl("./static_dependencies/noble-curves/secp256k1.js"),
            import_decl("./static_dependencies/noble-hashes/sha3.js")
          ]
        )

      result = RawBroadcast.extract_from_ast(ast, "grvt.ts")

      assert result["signing_imports"] == ["ethers", "noble-curves"]
      assert result["eip712_builder"] == true
    end

    test "emits an entry on imports alone even with no broadcast method" do
      ast =
        ast("dex", [method("fetchTicker", true, [])], [
          import_decl("./static_dependencies/noble-curves/secp256k1.js")
        ])

      result = RawBroadcast.extract_from_ast(ast, "dex.ts")

      assert result["signing_imports"] == ["noble-curves"]
      assert result["broadcast_methods"] == %{}
      assert result["eip712_builder"] == false
    end
  end

  describe "extract_from_ast/2 — no signal" do
    test "returns nil for a plain exchange with no signing signal" do
      ast = ast("binance", [method("createOrder", true, ["sign"]), method("fetchTicker", true, [])])
      assert RawBroadcast.extract_from_ast(ast, "binance.ts") == nil
    end

    test "returns nil when there is no exported class" do
      ast = %{body: [import_decl("ethers")]}
      assert RawBroadcast.extract_from_ast(ast, "x.ts") == nil
    end
  end

  describe "write_stats/1" do
    test "counts exchanges with at least one broadcast method" do
      exchanges = [
        %{"broadcast_methods" => %{"withdraw" => ["signEIP712"]}},
        %{"broadcast_methods" => %{}}
      ]

      assert RawBroadcast.write_stats(exchanges) == %{"with_broadcast" => 1}
    end
  end
end

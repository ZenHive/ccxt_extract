defmodule CcxtExtract.AstNormalizeTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.AstNormalize

  doctest AstNormalize, import: true

  describe "normalize/1 — :type atom conversion" do
    test "rewrites atom :type values to PascalCase strings" do
      input = %{type: :block_statement, body: []}
      assert AstNormalize.normalize(input) == %{type: "BlockStatement", body: []}
    end

    test "rewrites atom values under string \"type\" keys" do
      input = %{"type" => :variable_declaration, "kind" => :const}
      assert AstNormalize.normalize(input) == %{"type" => "VariableDeclaration", "kind" => :const}
    end

    test "applies TS prefix rule to :ts_* atoms" do
      input = %{type: :ts_array_type}
      assert AstNormalize.normalize(input) == %{type: "TSArrayType"}
    end

    test "leaves string :type values untouched" do
      input = %{type: "AlreadyNormalized", body: []}
      assert AstNormalize.normalize(input) == input
    end

    test "leaves nil / true / false :type values untouched" do
      assert AstNormalize.normalize(%{type: nil}) == %{type: nil}
      assert AstNormalize.normalize(%{type: true}) == %{type: true}
      assert AstNormalize.normalize(%{type: false}) == %{type: false}
    end

    test "does not touch non-:type atom values" do
      input = %{type: :identifier, kind: :const, async: true, computed: false}

      assert AstNormalize.normalize(input) == %{
               type: "Identifier",
               kind: :const,
               async: true,
               computed: false
             }
    end
  end

  describe "normalize/1 — recursion" do
    test "walks nested maps" do
      input = %{
        type: :program,
        body: %{type: :block_statement, inner: %{type: :literal, value: 1}}
      }

      assert AstNormalize.normalize(input) == %{
               type: "Program",
               body: %{type: "BlockStatement", inner: %{type: "Literal", value: 1}}
             }
    end

    test "walks lists of nodes" do
      input = [
        %{type: :identifier, name: "a"},
        %{type: :literal, value: 1},
        "raw-string",
        42
      ]

      assert AstNormalize.normalize(input) == [
               %{type: "Identifier", name: "a"},
               %{type: "Literal", value: 1},
               "raw-string",
               42
             ]
    end

    test "walks lists nested inside maps and vice versa" do
      input = %{
        type: :program,
        body: [
          %{type: :variable_declaration, declarations: [%{type: :variable_declarator}]}
        ]
      }

      assert AstNormalize.normalize(input) == %{
               type: "Program",
               body: [
                 %{type: "VariableDeclaration", declarations: [%{type: "VariableDeclarator"}]}
               ]
             }
    end

    test "returns primitives unchanged" do
      assert AstNormalize.normalize(nil) == nil
      assert AstNormalize.normalize(42) == 42
      assert AstNormalize.normalize("hello") == "hello"
      assert AstNormalize.normalize(:some_atom) == :some_atom
    end
  end

  describe "normalize/1 — structs" do
    test "returns structs unchanged (does not recurse)" do
      dt = ~U[2026-04-15 00:00:00Z]
      assert AstNormalize.normalize(dt) == dt
    end

    test "struct held inside a map is preserved without walking its fields" do
      dt = ~U[2026-04-15 00:00:00Z]
      input = %{type: :program, extracted_at: dt}

      assert AstNormalize.normalize(input) == %{type: "Program", extracted_at: dt}
    end
  end

  describe "normalize/1 — idempotence and JSON safety" do
    test "second normalize pass is a no-op (string :type stays a string)" do
      input = %{type: :block_statement, body: [%{type: :return_statement}]}
      once = AstNormalize.normalize(input)
      assert AstNormalize.normalize(once) == once
    end

    test "output contains no atom :type values (ready for Jason.encode)" do
      input = %{
        type: :program,
        body: [%{type: :ts_type_reference, typeArguments: [%{type: :ts_string_keyword}]}]
      }

      encoded = input |> AstNormalize.normalize() |> Jason.encode!()
      decoded = Jason.decode!(encoded)

      assert decoded["type"] == "Program"
      assert hd(decoded["body"])["type"] == "TSTypeReference"
      assert hd(hd(decoded["body"])["typeArguments"])["type"] == "TSStringKeyword"
    end
  end

  describe "to_encodable/1 — sorted-key emit" do
    test "emits map keys in ascending order regardless of insertion order" do
      a = AstNormalize.to_encodable(%{"c" => 1, "a" => 2, "b" => 3})
      b = AstNormalize.to_encodable(%{"a" => 2, "b" => 3, "c" => 1})
      assert Jason.encode!(a) == Jason.encode!(b)
      assert Jason.encode!(a) == ~s({"a":2,"b":3,"c":1})
    end

    test "sorts keys recursively at every depth" do
      input = %{"z" => %{"y" => 1, "x" => 2}, "a" => %{"d" => 3, "c" => 4}}
      encoded = input |> AstNormalize.to_encodable() |> Jason.encode!()
      assert encoded == ~s({"a":{"c":4,"d":3},"z":{"x":2,"y":1}})
    end

    test "still rewrites :type atoms to PascalCase" do
      input = %{type: :block_statement, body: []}
      encoded = input |> AstNormalize.to_encodable() |> Jason.encode!()
      assert Jason.decode!(encoded) == %{"body" => [], "type" => "BlockStatement"}
    end

    test "coerces atom keys to strings before sorting" do
      encoded = %{b: 1, a: 2} |> AstNormalize.to_encodable() |> Jason.encode!()
      assert encoded == ~s({"a":2,"b":1})
    end

    test "preserves list element order" do
      encoded = [3, 1, 2] |> AstNormalize.to_encodable() |> Jason.encode!()
      assert encoded == "[3,1,2]"
    end

    test "walks lists nested inside maps" do
      input = %{"items" => [%{"b" => 1, "a" => 2}, %{"d" => 3, "c" => 4}]}
      encoded = input |> AstNormalize.to_encodable() |> Jason.encode!()
      assert encoded == ~s({"items":[{"a":2,"b":1},{"c":4,"d":3}]})
    end

    test "is idempotent — re-wrapping an OrderedObject re-sorts" do
      once = AstNormalize.to_encodable(%{"c" => 1, "a" => 2})
      twice = AstNormalize.to_encodable(once)
      assert Jason.encode!(once) == Jason.encode!(twice)
    end

    test "passes non-OrderedObject structs through unchanged" do
      dt = ~U[2026-04-15 00:00:00Z]
      assert AstNormalize.to_encodable(dt) == dt

      assert %{type: :program, at: dt} |> AstNormalize.to_encodable() |> Jason.encode!() ==
               ~s({"at":"2026-04-15T00:00:00Z","type":"Program"})
    end

    test "returns primitives unchanged" do
      assert AstNormalize.to_encodable(nil) == nil
      assert AstNormalize.to_encodable(42) == 42
      assert AstNormalize.to_encodable("hello") == "hello"
    end
  end

  describe "atom_to_pascal/1" do
    test "single-token atoms capitalize first letter" do
      assert AstNormalize.atom_to_pascal(:super) == "Super"
      assert AstNormalize.atom_to_pascal(:program) == "Program"
    end

    test "multi-token atoms join without separators" do
      assert AstNormalize.atom_to_pascal(:block_statement) == "BlockStatement"
      assert AstNormalize.atom_to_pascal(:variable_declarator) == "VariableDeclarator"
    end

    test "ts_-prefixed atoms produce TS<Pascal> with uppercase TS" do
      assert AstNormalize.atom_to_pascal(:ts_array_type) == "TSArrayType"
      assert AstNormalize.atom_to_pascal(:ts_string_keyword) == "TSStringKeyword"
      assert AstNormalize.atom_to_pascal(:ts_type_parameter_instantiation) == "TSTypeParameterInstantiation"
    end
  end
end

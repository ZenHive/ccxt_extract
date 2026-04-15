defmodule CcxtExtract.HandleErrorsTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.HandleErrors
  alias Mix.Tasks.CcxtExtract.HandleErrors, as: HandleErrorsTask

  # Mock AST for a class with a handleErrors() method
  @handle_errors_method %{
    type: :method_definition,
    key: %{name: "handleErrors"},
    value: %{
      async: false,
      params: [
        %{type: :identifier, name: "code", typeAnnotation: nil},
        %{type: :identifier, name: "reason", typeAnnotation: nil},
        %{type: :identifier, name: "url", typeAnnotation: nil},
        %{type: :identifier, name: "method", typeAnnotation: nil},
        %{type: :identifier, name: "headers", typeAnnotation: nil},
        %{type: :identifier, name: "body", typeAnnotation: nil},
        %{type: :identifier, name: "response", typeAnnotation: nil},
        %{type: :identifier, name: "requestHeaders", typeAnnotation: nil},
        %{type: :identifier, name: "requestBody", typeAnnotation: nil}
      ],
      returnType: nil,
      body: %{
        type: :function_body,
        body: [
          %{type: :if_statement, test: %{type: :binary_expression}},
          %{type: :variable_declaration, declarations: [%{type: :variable_declarator}]},
          %{type: :if_statement, test: %{type: :call_expression}},
          %{type: :return_statement, argument: nil}
        ],
        start: 5000,
        end: 6000
      }
    }
  }

  @describe_method %{
    type: :method_definition,
    key: %{name: "describe"},
    value: %{
      async: false,
      params: [],
      returnType: nil,
      body: %{body: [%{type: :return_statement}]}
    }
  }

  @sign_method %{
    type: :method_definition,
    key: %{name: "sign"},
    value: %{
      async: false,
      params: [%{type: :identifier, name: "path", typeAnnotation: nil}],
      returnType: nil,
      body: %{body: [%{type: :return_statement}]}
    }
  }

  # Builds a mock AST with a class containing the given methods
  defp mock_ast(methods, class_name \\ "binance") do
    %{
      body: [
        %{
          type: :export_default_declaration,
          declaration: %{
            type: :class_declaration,
            id: %{name: class_name},
            superClass: %{name: "Exchange"},
            body: %{body: methods}
          }
        }
      ]
    }
  end

  describe "extract_from_ast/2" do
    test "extracts handleErrors method when present" do
      ast = mock_ast([@describe_method, @handle_errors_method, @sign_method])
      result = HandleErrors.extract_from_ast(ast, "binance.ts")

      assert result["id"] == "binance"
      assert result["class_name"] == "binance"
      assert result["file"] == "binance.ts"
      assert result["handle_errors"]
      assert result["handle_errors"]["statements"] == 4
      assert result["handle_errors"]["async"] == false
    end

    test "returns handle_errors as nil when method absent" do
      ast = mock_ast([@describe_method, @sign_method], "ace")
      result = HandleErrors.extract_from_ast(ast, "ace.ts")

      assert result["id"] == "ace"
      assert result["handle_errors"] == nil
    end

    test "returns nil when no exported class" do
      ast = %{body: [%{type: :import_declaration, source: %{value: "foo"}}]}
      assert HandleErrors.extract_from_ast(ast, "not_a_class.ts") == nil
    end

    test "falls back to filename for class name when id is nil" do
      ast = %{
        body: [
          %{
            type: :export_default_declaration,
            declaration: %{
              type: :class_declaration,
              id: nil,
              body: %{body: [@describe_method]}
            }
          }
        ]
      }

      result = HandleErrors.extract_from_ast(ast, "anonymous.ts")
      assert result["id"] == "anonymous"
      assert result["class_name"] == nil
    end

    test "extracts handleErrors params via Methods helpers" do
      ast = mock_ast([@handle_errors_method])
      result = HandleErrors.extract_from_ast(ast, "binance.ts")

      params = result["handle_errors"]["params"]
      assert length(params) == 9
      assert Enum.at(params, 0)["name"] == "code"
      assert Enum.at(params, 6)["name"] == "response"
    end

    test "includes exceptions fields (nil when no describe file)" do
      ast = mock_ast([@handle_errors_method])
      result = HandleErrors.extract_from_ast(ast, "binance.ts")

      # extract_from_ast calls load_describe_exceptions which may or may not find files
      assert Map.has_key?(result, "exceptions")
      assert Map.has_key?(result, "http_exceptions")
    end
  end

  describe "find_handle_errors_method/1" do
    test "finds handleErrors among multiple methods" do
      result =
        HandleErrors.find_handle_errors_method([
          @describe_method,
          @handle_errors_method,
          @sign_method
        ])

      assert result.key.name == "handleErrors"
    end

    test "returns nil when handleErrors is absent" do
      assert HandleErrors.find_handle_errors_method([@describe_method, @sign_method]) == nil
    end

    test "returns nil for empty class body" do
      assert HandleErrors.find_handle_errors_method([]) == nil
    end
  end

  describe "MethodAST.extract/1" do
    test "returns nil for nil input" do
      assert CcxtExtract.MethodAST.extract(nil) == nil
    end

    test "extracts params, return_type, async, statements, and body" do
      result = CcxtExtract.MethodAST.extract(@handle_errors_method)

      assert is_list(result["params"])
      assert length(result["params"]) == 9
      assert result["return_type"] == nil
      assert result["async"] == false
      assert result["statements"] == 4
      assert is_map(result["body"])
    end

    test "body AST is the raw value.body node" do
      result = CcxtExtract.MethodAST.extract(@handle_errors_method)

      body = result["body"]
      assert body.type == "FunctionBody"
      assert body.start == 5000
      assert body.end == 6000
      assert length(body.body) == 4
    end
  end

  describe "load_describe_exceptions/1" do
    @tag :tmp_dir
    test "returns {nil, nil} when describe file missing", %{tmp_dir: _tmp_dir} do
      # Uses a non-existent exchange id — no describe file will exist
      assert HandleErrors.load_describe_exceptions("nonexistent_exchange_zzz") == {nil, nil}
    end
  end

  describe "JSON round-trip" do
    test "atom keys become string keys at all nesting depths" do
      ast = mock_ast([@handle_errors_method])
      exchange = HandleErrors.extract_from_ast(ast, "binance.ts")

      json = Jason.encode!(exchange)
      decoded = Jason.decode!(json)

      # Top level
      assert is_binary(decoded |> Map.keys() |> hd())
      # handle_errors level
      assert is_binary(decoded["handle_errors"] |> Map.keys() |> hd())
      # Body level — atom keys converted to strings
      assert decoded["handle_errors"]["body"]["type"] == "FunctionBody"
      # Nested statement
      first_stmt = hd(decoded["handle_errors"]["body"]["body"])
      assert is_binary(first_stmt |> Map.keys() |> hd())
    end
  end

  describe "Mix.Tasks.CcxtExtract.HandleErrors.run/1 CLI validation" do
    test "rejects unknown switches" do
      assert_raise Mix.Error, ~r/Unknown option/, fn ->
        HandleErrorsTask.run(["--typo"])
      end
    end

    test "rejects positional arguments" do
      assert_raise Mix.Error, ~r/Unexpected argument/, fn ->
        HandleErrorsTask.run(["rest"])
      end
    end
  end
end

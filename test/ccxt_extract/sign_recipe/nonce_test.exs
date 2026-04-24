defmodule CcxtExtract.SignRecipe.NonceTest do
  @moduledoc """
  Unit tests for `CcxtExtract.SignRecipe.Nonce` — the Task 67 derivation
  that classifies the canonical timestamp / nonce binding as
  `{source, format}`.

  Uses synthetic AST fixtures; no file I/O. Corpus-level assertions live
  in `test/integration/cached/sign_recipe_cached_test.exs`.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.SignRecipe.Nonce

  # --- AST builder helpers (mirrors canonical_string_test.exs style) ---

  defp identifier(name), do: %{"type" => "Identifier", "name" => name}
  defp literal(value), do: %{"type" => "Literal", "value" => value}
  defp this_expression, do: %{"type" => "ThisExpression"}

  defp this_call(method, args) do
    %{
      "type" => "CallExpression",
      "callee" => %{
        "type" => "MemberExpression",
        "object" => this_expression(),
        "property" => identifier(method)
      },
      "arguments" => args
    }
  end

  defp method_call(receiver, method, args) do
    %{
      "type" => "CallExpression",
      "callee" => %{
        "type" => "MemberExpression",
        "object" => receiver,
        "property" => identifier(method)
      },
      "arguments" => args
    }
  end

  defp binary(op, l, r), do: %{"type" => "BinaryExpression", "operator" => op, "left" => l, "right" => r}

  defp var_decl(name, init) do
    %{
      "type" => "VariableDeclaration",
      "kind" => "const",
      "declarations" => [
        %{
          "type" => "VariableDeclarator",
          "id" => identifier(name),
          "init" => init
        }
      ]
    }
  end

  # --- Terminal-reason short-circuit ---

  describe "terminal unresolved_reason short-circuit" do
    test "ambiguous_ast returns nil" do
      body = [var_decl("timestamp", this_call("milliseconds", []))]
      assert is_nil(Nonce.derive(body, "ambiguous_ast"))
    end

    test "custom_signing_family returns nil" do
      body = [var_decl("timestamp", this_call("milliseconds", []))]
      assert is_nil(Nonce.derive(body, "custom_signing_family"))
    end

    test "no_sign_method returns nil" do
      assert is_nil(Nonce.derive([], "no_sign_method"))
    end
  end

  # --- Null / empty input ---

  describe "empty or non-list input" do
    test "empty body returns nil" do
      assert is_nil(Nonce.derive([], "not_yet_derived"))
    end

    test "non-list body returns nil" do
      assert is_nil(Nonce.derive(%{"some" => "map"}, "not_yet_derived"))
    end

    test "body with no timestamp bindings returns nil" do
      body = [var_decl("auth", binary("+", identifier("method"), identifier("path")))]
      assert is_nil(Nonce.derive(body, "not_yet_derived"))
    end
  end

  # --- Direct source classifiers ---

  describe "direct classification" do
    test "this.nonce() → timestamp_ms / integer" do
      body = [var_decl("timestamp", this_call("nonce", []))]
      assert Nonce.derive(body, "not_yet_derived") == %{"source" => "timestamp_ms", "format" => "integer"}
    end

    test "this.milliseconds() → timestamp_ms / integer" do
      body = [var_decl("timestamp", this_call("milliseconds", []))]
      assert Nonce.derive(body, "not_yet_derived") == %{"source" => "timestamp_ms", "format" => "integer"}
    end

    test "this.seconds() → timestamp_sec / integer" do
      body = [var_decl("timestamp", this_call("seconds", []))]
      assert Nonce.derive(body, "not_yet_derived") == %{"source" => "timestamp_sec", "format" => "integer"}
    end

    test "this.microseconds() → timestamp_us / integer" do
      body = [var_decl("timestamp", this_call("microseconds", []))]
      assert Nonce.derive(body, "not_yet_derived") == %{"source" => "timestamp_us", "format" => "integer"}
    end

    test "this.nanoseconds() → timestamp_ns / integer" do
      body = [var_decl("timestamp", this_call("nanoseconds", []))]
      assert Nonce.derive(body, "not_yet_derived") == %{"source" => "timestamp_ns", "format" => "integer"}
    end

    test "Date.now() → timestamp_ms / integer (raw JS global, bitmex-style override)" do
      date_now = %{
        "type" => "CallExpression",
        "callee" => %{
          "type" => "MemberExpression",
          "object" => identifier("Date"),
          "property" => identifier("now")
        },
        "arguments" => []
      }

      body = [var_decl("timestamp", date_now)]
      assert Nonce.derive(body, "not_yet_derived") == %{"source" => "timestamp_ms", "format" => "integer"}
    end
  end

  # --- Wrapped forms ---

  describe ".toString() wrapper" do
    test "this.nonce().toString() → timestamp_ms / string (bybit/okx pattern)" do
      inner = this_call("nonce", [])
      wrapped = method_call(inner, "toString", [])
      body = [var_decl("timestamp", wrapped)]

      assert Nonce.derive(body, "not_yet_derived") == %{"source" => "timestamp_ms", "format" => "string"}
    end

    test "this.milliseconds().toString() → timestamp_ms / string" do
      wrapped = method_call(this_call("milliseconds", []), "toString", [])
      body = [var_decl("timestamp", wrapped)]

      assert Nonce.derive(body, "not_yet_derived") == %{"source" => "timestamp_ms", "format" => "string"}
    end

    test "toString on unrecognized inner → nil" do
      wrapped = method_call(identifier("something"), "toString", [])
      body = [var_decl("timestamp", wrapped)]

      assert is_nil(Nonce.derive(body, "not_yet_derived"))
    end
  end

  describe "this.iso8601 / this.ymdhms wrappers" do
    test "this.iso8601(this.milliseconds()) → timestamp_ms / iso8601 (okx pattern)" do
      inner = this_call("milliseconds", [])
      wrapped = this_call("iso8601", [inner])
      body = [var_decl("timestamp", wrapped)]

      assert Nonce.derive(body, "not_yet_derived") == %{"source" => "timestamp_ms", "format" => "iso8601"}
    end

    test "this.iso8601(this.nonce()) → timestamp_ms / iso8601" do
      wrapped = this_call("iso8601", [this_call("nonce", [])])
      body = [var_decl("timestamp", wrapped)]

      assert Nonce.derive(body, "not_yet_derived") == %{"source" => "timestamp_ms", "format" => "iso8601"}
    end

    test "this.ymdhms(this.nonce()) → timestamp_ms / iso8601 (htx variant)" do
      wrapped = this_call("ymdhms", [this_call("nonce", []), literal("T")])
      body = [var_decl("timestamp", wrapped)]

      assert Nonce.derive(body, "not_yet_derived") == %{"source" => "timestamp_ms", "format" => "iso8601"}
    end
  end

  describe "this.parseToInt(<ms> / 1000) wrapper" do
    test "this.parseToInt(this.milliseconds() / 1000) → timestamp_sec / integer (gate pattern)" do
      divided = binary("/", this_call("milliseconds", []), literal(1000))
      wrapped = this_call("parseToInt", [divided])
      body = [var_decl("timestamp", wrapped)]

      assert Nonce.derive(body, "not_yet_derived") == %{"source" => "timestamp_sec", "format" => "integer"}
    end

    test "this.parseToInt(this.nonce() / 1000) → timestamp_sec / integer" do
      divided = binary("/", this_call("nonce", []), literal(1000))
      wrapped = this_call("parseToInt", [divided])
      body = [var_decl("timestamp", wrapped)]

      assert Nonce.derive(body, "not_yet_derived") == %{"source" => "timestamp_sec", "format" => "integer"}
    end

    test "parseToInt with unrecognized inner returns nil" do
      divided = binary("/", identifier("something"), literal(1000))
      body = [var_decl("timestamp", this_call("parseToInt", [divided]))]

      assert is_nil(Nonce.derive(body, "not_yet_derived"))
    end
  end

  describe "BinaryExpression + offset" do
    test "this.seconds() + 60 → timestamp_sec / integer (lighter deadline)" do
      init = binary("+", this_call("seconds", []), literal(60))
      body = [var_decl("deadline", init)]

      assert Nonce.derive(body, "not_yet_derived") == %{"source" => "timestamp_sec", "format" => "integer"}
    end

    test "this.milliseconds() + <drift> → timestamp_ms / integer (drift-corrected ms)" do
      # Pattern: exchanges that compensate for local clock drift by adding
      # a cached offset to the millisecond timestamp before signing.
      init = binary("+", this_call("milliseconds", []), identifier("timeDifference"))
      body = [var_decl("timestamp", init)]

      assert Nonce.derive(body, "not_yet_derived") == %{"source" => "timestamp_ms", "format" => "integer"}
    end

    test "this.microseconds() + offset → nil (narrower than ms/sec)" do
      # The BinaryExpression widener covers ms + sec only. Us/ns drift
      # correction is hypothetical; stay honest until a real exchange surfaces it.
      init = binary("+", this_call("microseconds", []), literal(500))
      body = [var_decl("nonce", init)]

      assert is_nil(Nonce.derive(body, "not_yet_derived"))
    end
  end

  # --- Multi-binding aggregation ---

  describe "multiple matching bindings" do
    test "two bindings with same classification → single emit (deribit pattern)" do
      # Deribit-style: `const timestamp = this.nonce().toString();
      #                 const nonce = this.nonce().toString();`
      # Both classify as {timestamp_ms, string}; dedupe to single emit.
      wrapped = method_call(this_call("nonce", []), "toString", [])
      body = [var_decl("timestamp", wrapped), var_decl("nonce", wrapped)]

      assert Nonce.derive(body, "not_yet_derived") == %{"source" => "timestamp_ms", "format" => "string"}
    end

    test "two bindings with differing classifications → nil" do
      # Aster / hybrid pattern: ms integer for auth + us integer for v3.
      body = [
        var_decl("timestamp", this_call("milliseconds", [])),
        var_decl("nonce", this_call("microseconds", []))
      ]

      assert is_nil(Nonce.derive(body, "not_yet_derived"))
    end

    test "one matching + one unmatched → single emit" do
      # Unmatched binding is silently dropped; the matching one surfaces.
      body = [
        var_decl("timestamp", this_call("milliseconds", [])),
        var_decl("nonce", identifier("something_opaque"))
      ]

      assert Nonce.derive(body, "not_yet_derived") == %{"source" => "timestamp_ms", "format" => "integer"}
    end
  end

  # --- timestamp_binding_names/1 (AuthHeaders consumer contract) ---

  describe "timestamp_binding_names/1" do
    test "returns names of bindings whose init classifies as a timestamp" do
      body = [
        var_decl("timestamp", this_call("milliseconds", [])),
        var_decl("nonce", this_call("nonce", [])),
        var_decl("other", identifier("unrelated"))
      ]

      names = Nonce.timestamp_binding_names(body)
      assert Enum.sort(names) == ["nonce", "timestamp"]
    end

    test "drops bindings whose init doesn't classify" do
      body = [
        var_decl("timestamp", identifier("opaque_thing")),
        var_decl("nonce", this_call("milliseconds", []))
      ]

      assert Nonce.timestamp_binding_names(body) == ["nonce"]
    end

    test "drops bindings whose name isn't in the whitelist" do
      body = [var_decl("arbitraryNameButMsInit", this_call("milliseconds", []))]
      assert Nonce.timestamp_binding_names(body) == []
    end

    test "non-list input returns []" do
      assert Nonce.timestamp_binding_names(nil) == []
      assert Nonce.timestamp_binding_names(%{"x" => 1}) == []
    end
  end
end

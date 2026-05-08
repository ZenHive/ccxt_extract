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

  # --- Branch coverage: depth exhaustion + unrecognized inits ---

  describe "identifier resolution depth + fallthrough" do
    test "identifier referencing an unbound name returns nil (no chain)" do
      # `const timestamp = mysteryName;` — no binding for mysteryName, so
      # the identifier classify clause reaches Map.get/2 → nil.
      body = [var_decl("timestamp", identifier("mysteryName"))]
      assert is_nil(Nonce.derive(body, "not_yet_derived"))
    end

    test "deep alias chain resolves via identifier substitution" do
      # `const a = this.milliseconds(); const b = a; const c = b;
      #  const timestamp = c;` — exercises the recursive identifier-init
      # resolution branch (classify_init on Identifier → look up binding
      # → classify_init on the resolved init).
      body = [
        var_decl("a", this_call("milliseconds", [])),
        var_decl("b", identifier("a")),
        var_decl("c", identifier("b")),
        var_decl("timestamp", identifier("c"))
      ]

      assert Nonce.derive(body, "not_yet_derived") ==
               %{"source" => "timestamp_ms", "format" => "integer"}
    end

    test "self-referential cycle bottoms out at depth limit instead of looping" do
      # `const a = b; const b = a; const timestamp = a;` — the chain
      # would loop forever without the depth guard. Verify the guard
      # returns nil rather than blowing the stack.
      body = [
        var_decl("a", identifier("b")),
        var_decl("b", identifier("a")),
        var_decl("timestamp", identifier("a"))
      ]

      assert is_nil(Nonce.derive(body, "not_yet_derived"))
    end

    test "this.iso8601 with completely unrecognized inner returns nil" do
      # iso8601(<unknown identifier>) — the inner doesn't classify, the
      # iso8601 wrapper exits via the nil branch.
      wrapped = this_call("iso8601", [identifier("unboundName")])
      body = [var_decl("timestamp", wrapped)]

      assert is_nil(Nonce.derive(body, "not_yet_derived"))
    end

    test "completely opaque init (e.g. literal value) returns nil via fallthrough" do
      # A binding initialized to a bare literal isn't recognized by any
      # classifier clause, so it falls through to the catch-all
      # `classify_init(_, _, _)` returning nil.
      body = [var_decl("timestamp", literal(12_345))]
      assert is_nil(Nonce.derive(body, "not_yet_derived"))
    end
  end

  # --- Task 72: timestamp/2 alias + per-exchange shape coverage ---

  describe "timestamp/2 (Task 72 alias)" do
    test "mirrors derive/2 on every recognized shape" do
      # Spot-check a handful of inputs and confirm timestamp/2 returns the
      # same classification as derive/2. The aliasing contract is what
      # Derive.derive/2 relies on to populate `timestamp` in lockstep
      # with `nonce`.
      bodies = [
        [var_decl("timestamp", this_call("nonce", []))],
        [var_decl("timestamp", this_call("milliseconds", []))],
        [var_decl("timestamp", this_call("seconds", []))],
        [var_decl("timestamp", this_call("nanoseconds", []))],
        [var_decl("timestamp", method_call(this_call("nonce", []), "toString", []))],
        [var_decl("timestamp", this_call("iso8601", [this_call("milliseconds", [])]))]
      ]

      for body <- bodies do
        assert Nonce.timestamp(body, "not_yet_derived") ==
                 Nonce.derive(body, "not_yet_derived"),
               "timestamp/2 must mirror derive/2 on shape #{inspect(body)}"
      end
    end

    test "honors terminal short-circuit reasons" do
      body = [var_decl("timestamp", this_call("milliseconds", []))]
      assert is_nil(Nonce.timestamp(body, "ambiguous_ast"))
      assert is_nil(Nonce.timestamp(body, "custom_signing_family"))
      assert is_nil(Nonce.timestamp(body, "no_sign_method"))
    end

    test "returns nil on empty / non-list input" do
      assert is_nil(Nonce.timestamp([], "not_yet_derived"))
      assert is_nil(Nonce.timestamp(nil, "not_yet_derived"))
      assert is_nil(Nonce.timestamp(%{"x" => 1}, "not_yet_derived"))
    end
  end

  # Per-exchange shape coverage. These are synthetic AST fixtures whose
  # shape mirrors the canonical sign() / nonce() flow each named exchange
  # ships in CCXT. The corpus-level cached test
  # (test/integration/cached/sign_recipe_cached_test.exs) re-asserts the
  # same outcomes against the real committed priv/output/<id>.json.
  describe "per-exchange timestamp source classification" do
    test "binance — timestamp_ms / integer (this.milliseconds())" do
      # Binance's sign() reaches for `this.milliseconds()` directly; the
      # canonical CCXT base also resolves `this.nonce() === milliseconds()`,
      # so either pattern lands the same `{timestamp_ms, integer}` record.
      body = [var_decl("timestamp", this_call("milliseconds", []))]
      assert Nonce.timestamp(body, "not_yet_derived") == %{"source" => "timestamp_ms", "format" => "integer"}
    end

    test "deribit — timestamp_ms / string (this.nonce().toString())" do
      # Deribit binds `const timestamp = this.nonce().toString()` (and a
      # parallel `nonce` binding to the same expression) — both classify
      # as ms / string. Multi-binding agreement collapses to a single
      # emission.
      wrapped = method_call(this_call("nonce", []), "toString", [])
      body = [var_decl("timestamp", wrapped), var_decl("nonce", wrapped)]

      assert Nonce.timestamp(body, "not_yet_derived") == %{"source" => "timestamp_ms", "format" => "string"}
    end

    test "bitmex — timestamp_ms / string (Date.now() global)" do
      # Bitmex-style: an exchange that overrides sign() and reaches for
      # the raw `Date.now()` JS global rather than CCXT's `this.nonce()`.
      # Date.now() returns ms, then `.toString()` flips to wire format.
      date_now = %{
        "type" => "CallExpression",
        "callee" => %{
          "type" => "MemberExpression",
          "object" => identifier("Date"),
          "property" => identifier("now")
        },
        "arguments" => []
      }

      wrapped = method_call(date_now, "toString", [])
      body = [var_decl("timestamp", wrapped)]

      assert Nonce.timestamp(body, "not_yet_derived") == %{"source" => "timestamp_ms", "format" => "string"}
    end

    test "kraken — timestamp_ns / string (nanoseconds + .toString())" do
      # Kraken-style nanosecond nonce. The committed priv/output/kraken.json
      # currently shows `{timestamp_ms, string}` (CCXT's kraken.ts uses
      # `this.nonce()`, which is base = milliseconds), but if a future
      # variant ships a `this.nanoseconds().toString()` binding, this
      # test pins the expected ns / string classification.
      wrapped = method_call(this_call("nanoseconds", []), "toString", [])
      body = [var_decl("nonce", wrapped)]

      assert Nonce.timestamp(body, "not_yet_derived") == %{"source" => "timestamp_ns", "format" => "string"}
    end

    test "okx — timestamp_ms / iso8601 (this.iso8601(this.milliseconds()))" do
      # OKX wraps the ms timestamp in this.iso8601(...) before stamping
      # it on OK-ACCESS-TIMESTAMP, so the wire format is the iso8601
      # rendering even though the source is still milliseconds.
      wrapped = this_call("iso8601", [this_call("milliseconds", [])])
      body = [var_decl("timestamp", wrapped)]

      assert Nonce.timestamp(body, "not_yet_derived") == %{"source" => "timestamp_ms", "format" => "iso8601"}
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

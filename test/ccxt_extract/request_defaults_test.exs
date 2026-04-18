defmodule CcxtExtract.RequestDefaultsTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.RequestDefaults

  defp parse_class(source) do
    {:ok, ast} = OXC.parse(source, "e.ts")
    RequestDefaults.extract_from_ast(ast, "e.ts")
  end

  defp wrap(body) do
    """
    export default class E extends Exchange {
    #{body}
    }
    """
  end

  describe "extract_object_expression/1 + classify_property_value/1 primitives" do
    test "string literal" do
      source =
        wrap("""
          m() { return this.publicPostX({'type': 'exchangeStatus'}); }
        """)

      result = parse_class(source)

      assert result["request_defaults"]["m"] ==
               %{"type" => %{"value" => "exchangeStatus", "kind" => "literal", "reason" => nil}}
    end

    test "numeric, boolean, null, undefined primitives" do
      source =
        wrap("""
          m() {
            return this.publicPostX({
              'n': 42,
              'b': true,
              'z': null,
              'u': undefined
            });
          }
        """)

      entries = parse_class(source)["request_defaults"]["m"]

      assert entries["n"] == %{"value" => 42, "kind" => "literal", "reason" => nil}
      assert entries["b"] == %{"value" => true, "kind" => "literal", "reason" => nil}
      assert entries["z"] == %{"value" => nil, "kind" => "literal", "reason" => nil}
      assert entries["u"] == %{"value" => nil, "kind" => "literal", "reason" => nil}
    end

    test "negative numeric literal (UnaryExpression)" do
      source =
        wrap("""
          m() { return this.publicPostX({'offset': -1}); }
        """)

      assert parse_class(source)["request_defaults"]["m"]["offset"] ==
               %{"value" => -1, "kind" => "literal", "reason" => nil}
    end

    test "nested object literal fully resolves" do
      source =
        wrap("""
          m() { return this.publicPostX({'meta': {'inner': 'x'}}); }
        """)

      assert parse_class(source)["request_defaults"]["m"]["meta"] ==
               %{"value" => %{"inner" => "x"}, "kind" => "literal", "reason" => nil}
    end

    test "nested object with any non-literal child → unresolved with value=nil (Honesty Rule)" do
      source =
        wrap("""
          m(x: string) { return this.publicPostX({'meta': {'a': 'lit', 'b': x}}); }
        """)

      assert parse_class(source)["request_defaults"]["m"]["meta"] ==
               %{"value" => nil, "kind" => "unresolved", "reason" => "dynamic_construction"}
    end

    test "array of literals resolves" do
      source =
        wrap("""
          m() { return this.publicPostX({'items': [1, 2, 'a']}); }
        """)

      assert parse_class(source)["request_defaults"]["m"]["items"] ==
               %{"value" => [1, 2, "a"], "kind" => "literal", "reason" => nil}
    end

    test "conditional expression value → unresolved/conditional_value" do
      source =
        wrap("""
          m(x: string) { return this.publicPostX({'mode': x === 'a' ? 'b' : 'c'}); }
        """)

      assert parse_class(source)["request_defaults"]["m"]["mode"] ==
               %{"value" => nil, "kind" => "unresolved", "reason" => "conditional_value"}
    end

    test "identifier reference value → unresolved/identifier_reference" do
      source =
        wrap("""
          m(x: string) { return this.publicPostX({'mode': x}); }
        """)

      assert parse_class(source)["request_defaults"]["m"]["mode"] ==
               %{"value" => nil, "kind" => "unresolved", "reason" => "identifier_reference"}
    end

    test "call expression value → unresolved/dynamic_construction" do
      source =
        wrap("""
          m() { return this.publicPostX({'ts': this.nonce()}); }
        """)

      assert parse_class(source)["request_defaults"]["m"]["ts"] ==
               %{"value" => nil, "kind" => "unresolved", "reason" => "dynamic_construction"}
    end

    test "computed key → _computed pseudo-entry with reason computed_key" do
      source =
        wrap("""
          m(k: string) { return this.publicPostX({[k]: 'v'}); }
        """)

      assert parse_class(source)["request_defaults"]["m"]["_computed"] ==
               %{"value" => nil, "kind" => "unresolved", "reason" => "computed_key"}
    end
  end

  describe "resolution tier 1 — direct ObjectExpression literal" do
    test "emits literal body" do
      source =
        wrap("""
          async fetchFoo(params = {}) {
            return this.publicPostFoo({'type': 'foo'});
          }
        """)

      assert parse_class(source)["request_defaults"] == %{
               "fetchFoo" => %{
                 "type" => %{"value" => "foo", "kind" => "literal", "reason" => nil}
               }
             }
    end
  end

  describe "resolution tier 2 — this.extend unwrap" do
    test "unwraps extend(literal, params)" do
      source =
        wrap("""
          async fetchFoo(params = {}) {
            return this.publicPostFoo(this.extend({'type': 'foo'}, params));
          }
        """)

      assert parse_class(source)["request_defaults"]["fetchFoo"] ==
               %{"type" => %{"value" => "foo", "kind" => "literal", "reason" => nil}}
    end
  end

  describe "resolution tier 3 — const/let identifier trace" do
    test "traces const to sole declarator (hyperliquid.fetchTime golden)" do
      source =
        wrap("""
          async fetchTime(params = {}) {
            const request = {'type': 'exchangeStatus'};
            return await this.publicPostInfo(this.extend(request, params));
          }
        """)

      assert parse_class(source)["request_defaults"]["fetchTime"] ==
               %{"type" => %{"value" => "exchangeStatus", "kind" => "literal", "reason" => nil}}
    end

    test "traces let to sole declarator" do
      source =
        wrap("""
          async fetchFoo(params = {}) {
            let request = {'type': 'foo'};
            return this.publicPostFoo(request);
          }
        """)

      assert parse_class(source)["request_defaults"]["fetchFoo"] ==
               %{"type" => %{"value" => "foo", "kind" => "literal", "reason" => nil}}
    end

    test "skips when identifier has two declarators in same scope" do
      source =
        wrap("""
          async m(params = {}) {
            const request = {'type': 'a'};
            const request2 = {'type': 'b'};
            const request = {'type': 'c'};
            return this.publicPostFoo(request);
          }
        """)

      assert Map.has_key?(parse_class(source)["request_defaults"], "m") == false
    end

    test "skips when identifier declared inside nested block" do
      source =
        wrap("""
          async m(params = {}) {
            if (true) {
              const request = {'type': 'x'};
            }
            return this.publicPostFoo(request);
          }
        """)

      assert Map.has_key?(parse_class(source)["request_defaults"], "m") == false
    end

    test "reassignment to same identifier forces skip (ndax.signIn shape)" do
      # `let request = {...}` declared once, then REASSIGNED (not redeclared)
      # before a second HTTP call. Both call sites trace back to the same
      # declarator, so without reassignment detection they'd collapse via
      # Enum.uniq and emit a stale literal for the second endpoint.
      source =
        wrap("""
          async signIn(params = {}) {
            let request = {'grant_type': 'client_credentials'};
            const response = await this.publicGetAuthenticate(this.extend(request, params));
            if (response) {
              request = {'Code': 'x'};
              const inner = await this.publicGetAuthenticate2FA(this.extend(request, params));
            }
            return response;
          }
        """)

      refute Map.has_key?(parse_class(source)["request_defaults"], "signIn")
    end

    test "update expression (x++) on traced identifier forces skip" do
      source =
        wrap("""
          async m(params = {}) {
            let request = {'type': 'x'};
            request++;
            return this.publicPostFoo(request);
          }
        """)

      refute Map.has_key?(parse_class(source)["request_defaults"], "m")
    end

    test "traces const whose init is this.extend(literal, params) — btcbox.fetchOrder shape" do
      source =
        wrap("""
          async fetchOrder(id: string, params = {}) {
            const request = this.extend({
              'id': id,
              'coin': 'BTC',
            }, params);
            return await this.privatePostTradeView(this.extend(request, params));
          }
        """)

      result = parse_class(source)["request_defaults"]["fetchOrder"]
      assert result["id"] == %{"value" => nil, "kind" => "unresolved", "reason" => "identifier_reference"}
      assert result["coin"] == %{"value" => "BTC", "kind" => "literal", "reason" => nil}
    end
  end

  describe "computed member calls — this[method](...)" do
    test "resolves this[method](request) when method traces to a sole string-literal declarator" do
      source =
        wrap("""
          async m(params = {}) {
            const method = 'publicPostX';
            const request = {'type': 'x'};
            return this[method](this.extend(request, params));
          }
        """)

      assert parse_class(source)["request_defaults"]["m"] ==
               %{"type" => %{"value" => "x", "kind" => "literal", "reason" => nil}}
    end

    test "skips when computed method name is a non-literal identifier" do
      source =
        wrap("""
          async m(method: string, params = {}) {
            const request = {'type': 'x'};
            return this[method](this.extend(request, params));
          }
        """)

      assert Map.has_key?(parse_class(source)["request_defaults"], "m") == false
    end

    test "skips when computed method name resolves to a non-HTTP-verb string" do
      source =
        wrap("""
          async m(params = {}) {
            const method = 'helperFn';
            const request = {'type': 'x'};
            return this[method](request);
          }
        """)

      assert Map.has_key?(parse_class(source)["request_defaults"], "m") == false
    end
  end

  describe "method-level skip semantics" do
    test "method with no HTTP calls is skipped" do
      source =
        wrap("""
          helperOnly() { return 42; }
        """)

      assert parse_class(source)["request_defaults"] == %{}
    end

    test "pure delegate method (no literal body) is skipped" do
      source =
        wrap("""
          async fetchMarkets(params = {}) {
            return await this.fetchSwapMarkets(params);
          }
        """)

      assert parse_class(source)["request_defaults"] == %{}
    end

    test "empty literal body is skipped (no properties to emit)" do
      source =
        wrap("""
          m(params = {}) {
            return this.publicPostFoo({});
          }
        """)

      assert parse_class(source)["request_defaults"] == %{}
    end

    test "is/handle callee prefix filters out the call site" do
      source =
        wrap("""
          m(params: any) { return this.isPostSomething({'type': 'x'}); }
        """)

      # this.isPostSomething matches the HTTP verb regex but is excluded by
      # the `is`/`handle` prefix filter in @non_interface_prefixes, so there
      # is no HTTP call site inside `m` and request_defaults for `m` is absent.
      assert parse_class(source)["request_defaults"] == %{}
    end

    test "callee prefix filter is scoped to callee name, not enclosing method name" do
      source =
        wrap("""
          isPostOnly(params: any) { return this.publicPostNothing({'type': 'x'}); }
        """)

      # The enclosing method is named `isPostOnly` (which would match the
      # prefix filter if it were checked there). The filter only runs on
      # callee names — the inner this.publicPostNothing() IS recognized as
      # an HTTP call site, so the literal body emits under `isPostOnly`.
      assert parse_class(source)["request_defaults"]["isPostOnly"] ==
               %{"type" => %{"value" => "x", "kind" => "literal", "reason" => nil}}
    end
  end

  describe "multiple call sites" do
    test "divergent bodies → method skipped" do
      source =
        wrap("""
          m(kind: string, params = {}) {
            if (kind === 'a') {
              return this.publicPostFoo({'type': 'a'});
            }
            return this.publicPostFoo({'type': 'b'});
          }
        """)

      assert Map.has_key?(parse_class(source)["request_defaults"], "m") == false
    end

    test "identical bodies → collapse to single entry" do
      source =
        wrap("""
          m(kind: string, params = {}) {
            if (kind === 'a') {
              return this.publicPostFoo({'type': 'x'});
            }
            return this.publicPostFoo({'type': 'x'});
          }
        """)

      assert parse_class(source)["request_defaults"]["m"] ==
               %{"type" => %{"value" => "x", "kind" => "literal", "reason" => nil}}
    end
  end

  describe "envelope metadata" do
    test "top-level counts match body shape" do
      source =
        wrap("""
          fetchA() { return this.publicPostA({'type': 'a', 'n': 1}); }
          fetchB() { return this.publicPostB({'ts': this.nonce()}); }
        """)

      result = parse_class(source)
      assert result["request_defaults_method_count"] == 2
      assert result["request_defaults_resolvable_count"] == 2
      assert result["request_defaults_unresolved_count"] == 1
    end
  end
end

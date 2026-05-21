defmodule CcxtExtract.WsAuthTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.WsAuth

  # --- Raw-entry fixture builders ---

  defp entry(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "class_name" => id,
        "file" => "#{id}.ts",
        "extends" => "#{id}Rest",
        "authenticate" => auth_absent()
      },
      overrides
    )
  end

  defp auth_absent do
    %{
      "defined" => false,
      "async" => false,
      "param_count" => 0,
      "credentials" => [],
      "sends_message" => false,
      "url_param_signal" => false,
      "message" => nil
    }
  end

  defp auth_sign_in(opts) do
    %{
      "defined" => true,
      "async" => true,
      "param_count" => 1,
      "credentials" => Keyword.get(opts, :credentials, ["apiKey", "secret"]),
      "sends_message" => true,
      "url_param_signal" => false,
      "message" => %{
        "op" => Keyword.get(opts, :op),
        "method" => Keyword.get(opts, :method),
        "keys" => Keyword.get(opts, :keys, ["op", "args"])
      }
    }
  end

  defp auth_url_param do
    %{
      "defined" => true,
      "async" => true,
      "param_count" => 1,
      "credentials" => ["apiKey", "secret"],
      "sends_message" => false,
      "url_param_signal" => true,
      "message" => nil
    }
  end

  defp auth_unknown do
    %{
      "defined" => true,
      "async" => true,
      "param_count" => 1,
      "credentials" => [],
      "sends_message" => false,
      "url_param_signal" => false,
      "message" => nil
    }
  end

  describe "build/2 — no WebSocket class" do
    test "nil entry yields the honest none_record" do
      assert WsAuth.build(nil, %{}) == WsAuth.none_record()
    end

    test "none_record is internally coherent" do
      r = WsAuth.none_record()
      assert r["mechanism"] == "none"
      assert r["source"] == "none"
      assert r["unresolved_reason"] == "no_ws_support"
      assert r["authenticate_defined"] == false
      assert is_nil(r["message"])
      assert is_nil(r["resolved_from"])
      assert r["credentials"] == []
      assert Enum.sort(Map.keys(r)) == Enum.sort(WsAuth.required_keys())
    end
  end

  describe "build/2 — Pro class without authenticate()" do
    test "a public-only WS class yields mechanism none tagged no_ws_auth" do
      e = entry("hyperliquid")
      r = WsAuth.build(e, %{"hyperliquid" => e})

      assert r["mechanism"] == "none"
      assert r["source"] == "none"
      assert r["unresolved_reason"] == "no_ws_auth"
      assert r["authenticate_defined"] == false
    end
  end

  describe "build/2 — mechanism classification" do
    test "an op-discriminant request object yields sign_in_message" do
      e = entry("bybit", %{"authenticate" => auth_sign_in(op: "auth")})
      r = WsAuth.build(e, %{"bybit" => e})

      assert r["mechanism"] == "sign_in_message"
      assert r["message"]["op"] == "auth"
      assert r["source"] == "pro_authenticate"
      assert r["resolved_from"] == "self"
      assert is_nil(r["unresolved_reason"])
    end

    test "a method-discriminant request object yields sign_in_message" do
      e = entry("deribit", %{"authenticate" => auth_sign_in(method: "public/auth", keys: ["jsonrpc", "method"])})
      r = WsAuth.build(e, %{"deribit" => e})

      assert r["mechanism"] == "sign_in_message"
      assert r["message"]["method"] == "public/auth"
      assert is_nil(r["message"]["op"])
    end

    test "a listenKey signal without a message yields url_param" do
      e = entry("binance", %{"authenticate" => auth_url_param()})
      r = WsAuth.build(e, %{"binance" => e})

      assert r["mechanism"] == "url_param"
      assert is_nil(r["message"])
      assert is_nil(r["unresolved_reason"])
    end

    test "an authenticate() matching no known shape yields unknown, not a forced category" do
      e = entry("oddex", %{"authenticate" => auth_unknown()})
      r = WsAuth.build(e, %{"oddex" => e})

      assert r["mechanism"] == "unknown"
      assert r["unresolved_reason"] == "auth_not_classifiable"
      assert is_nil(r["message"])
    end

    test "credentials are carried through from the resolved authenticate()" do
      e = entry("okx", %{"authenticate" => auth_sign_in(op: "login", credentials: ["apiKey", "password", "secret"])})
      r = WsAuth.build(e, %{"okx" => e})

      assert r["credentials"] == ["apiKey", "password", "secret"]
    end
  end

  describe "build/2 — extends-chain inheritance" do
    test "a child without authenticate() inherits the parent's, tagged with the ancestor id" do
      parent = entry("binance", %{"authenticate" => auth_url_param()})
      child = entry("binanceusdm", %{"extends" => "binance"})
      lookup = %{"binance" => parent, "binanceusdm" => child}

      r = WsAuth.build(child, lookup)

      assert r["mechanism"] == "url_param"
      assert r["resolved_from"] == "binance"
      assert r["authenticate_defined"] == true
    end

    test "a child that defines its own authenticate() resolves as self" do
      parent = entry("base", %{"authenticate" => auth_url_param()})
      child = entry("variant", %{"extends" => "base", "authenticate" => auth_sign_in(op: "auth")})
      r = WsAuth.build(child, %{"base" => parent, "variant" => child})

      assert r["mechanism"] == "sign_in_message"
      assert r["resolved_from"] == "self"
    end

    test "a cyclic extends chain terminates instead of looping forever" do
      a = entry("a", %{"extends" => "b"})
      b = entry("b", %{"extends" => "a", "authenticate" => auth_sign_in(op: "auth")})
      r = WsAuth.build(a, %{"a" => a, "b" => b})

      assert r["mechanism"] == "sign_in_message"
      assert r["resolved_from"] == "b"
    end
  end

  describe "closed-vocabulary exposers" do
    test "vocabularies are stable and non-empty" do
      assert "sign_in_message" in WsAuth.mechanisms()
      assert "header" in WsAuth.mechanisms()
      assert "none" in WsAuth.mechanisms()
      assert WsAuth.sources() == ~w(pro_authenticate none)
      assert WsAuth.unresolved_reasons() == ~w(no_ws_support no_ws_auth auth_not_classifiable)
    end

    test "every build/2 result carries exactly the required key set" do
      e = entry("ex", %{"authenticate" => auth_sign_in(op: "auth")})

      for record <- [WsAuth.build(e, %{"ex" => e}), WsAuth.none_record()] do
        assert Enum.sort(Map.keys(record)) == Enum.sort(WsAuth.required_keys())
      end
    end
  end

  describe "extract_from_ast/2" do
    test "extracts an op-discriminant sign-in message with a string literal" do
      source = """
      export default class bx extends bxRest {
          async authenticate (url, params = {}) {
              this.checkRequiredCredentials ();
              const request = { 'op': 'auth', 'args': [ this.apiKey, this.secret ] };
              this.watch (url, 'authenticated', request, 'authenticated');
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "bx.ts")
      e = WsAuth.extract_from_ast(ast, "bx.ts")
      auth = e["authenticate"]

      assert e["id"] == "bx"
      assert e["extends"] == "bxRest"
      assert auth["defined"] == true
      assert auth["async"] == true
      assert auth["param_count"] == 2
      assert auth["credentials"] == ["apiKey", "secret"]
      assert auth["sends_message"] == true
      assert auth["url_param_signal"] == false
      assert auth["message"]["op"] == "auth"
      assert is_nil(auth["message"]["method"])
      assert auth["message"]["keys"] == ["op", "args"]
    end

    test "resolves an identifier-valued op through a local const binding" do
      source = """
      export default class ox extends oxRest {
          async authenticate (params = {}) {
              const operation = 'login';
              const request = { 'op': operation, 'args': [] };
              this.watch (url, 'authenticated', request, 'authenticated');
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "ox.ts")
      e = WsAuth.extract_from_ast(ast, "ox.ts")

      assert e["authenticate"]["message"]["op"] == "login"
    end

    test "extracts a method-discriminant sign-in message" do
      source = """
      export default class dx extends dxRest {
          async authenticate (params = {}) {
              const request = { 'jsonrpc': '2.0', 'method': 'public/auth', 'params': {} };
              this.watch (url, 'h', this.extend (request, params), 'h');
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "dx.ts")
      auth = WsAuth.extract_from_ast(ast, "dx.ts")["authenticate"]

      assert auth["message"]["method"] == "public/auth"
      assert is_nil(auth["message"]["op"])
      assert auth["message"]["keys"] == ["jsonrpc", "method", "params"]
    end

    test "flags a listenKey URL-parameter flow with no sign-in message" do
      source = """
      export default class lk extends lkRest {
          async authenticate (params = {}) {
              const listenKey = await this.publicGetListenKey ();
              const url = this.urls['api']['ws'] + '/' + listenKey;
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "lk.ts")
      auth = WsAuth.extract_from_ast(ast, "lk.ts")["authenticate"]

      assert auth["defined"] == true
      assert auth["url_param_signal"] == true
      assert auth["sends_message"] == false
      assert is_nil(auth["message"])
    end

    test "a class with no authenticate() reports an honest absence" do
      source = """
      export default class plain extends plainRest {
          describe () { return this.deepExtend (super.describe (), { 'has': { 'ws': true } }); }
      }
      """

      {:ok, ast} = OXC.parse(source, "plain.ts")
      auth = WsAuth.extract_from_ast(ast, "plain.ts")["authenticate"]

      assert auth["defined"] == false
      assert is_nil(auth["message"])
      assert auth["credentials"] == []
    end

    test "extract_from_ast/2 output feeds build/2 end-to-end" do
      source = """
      export default class ex extends exRest {
          async authenticate (params = {}) {
              const request = { 'op': 'login', 'args': [ this.apiKey ] };
              this.watch (url, 'h', request, 'h');
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "ex.ts")
      e = WsAuth.extract_from_ast(ast, "ex.ts")
      r = WsAuth.build(e, %{"ex" => e})

      assert r["mechanism"] == "sign_in_message"
      assert r["message"]["op"] == "login"
      assert r["credentials"] == ["apiKey"]
    end
  end
end

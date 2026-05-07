defmodule CcxtExtract.RequestShapeTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.RequestShape
  alias CcxtExtract.RequestShape.BodyEncoding
  alias CcxtExtract.RequestShape.Derive
  alias CcxtExtract.RequestShape.VerbPath

  describe "null_record/0" do
    test "has the five required keys" do
      record = RequestShape.null_record()

      required = ~w(endpoints body_encoding content_type unresolved_reason patch_count)
      assert record |> Map.keys() |> Enum.sort() == Enum.sort(required)
    end

    test "nulls every derivation field and tags unresolved_reason = not_yet_derived" do
      record = RequestShape.null_record()

      for field <- ~w(endpoints body_encoding content_type) do
        assert Map.fetch!(record, field) == nil,
               "expected #{field} to start nil in the scaffold"
      end

      assert record["unresolved_reason"] == "not_yet_derived"
      assert record["patch_count"] == 0
    end
  end

  describe "build_default/1" do
    test "returns one null record per section" do
      sections = ["private", "sapi", "fapiPrivate"]
      record_map = RequestShape.build_default(sections)

      assert record_map |> Map.keys() |> Enum.sort() == Enum.sort(sections)
      assert Enum.all?(record_map, fn {_k, v} -> v == RequestShape.null_record() end)
    end

    test "returns an empty map for nil (sign_method absent)" do
      assert RequestShape.build_default(nil) == %{}
    end

    test "returns an empty map for [] (sign_method present but no auth gates)" do
      assert RequestShape.build_default([]) == %{}
    end

    test "collapses duplicate section names" do
      record_map = RequestShape.build_default(["private", "private", "sapi"])
      assert record_map |> Map.keys() |> Enum.sort() == ["private", "sapi"]
    end
  end

  describe "derivation_fields/0 and all_derivation_fields_populated?/1 (Phase 11 biconditional)" do
    test "derivation_fields/0 returns the three fields populated by Tasks 70 + 71" do
      assert RequestShape.derivation_fields() == ["endpoints", "body_encoding", "content_type"]
    end

    test "derivation_fields/0 is a strict subset of required_keys/0" do
      assert RequestShape.derivation_fields() -- RequestShape.required_keys() == []
      leftover = RequestShape.required_keys() -- RequestShape.derivation_fields()
      assert Enum.sort(leftover) == ["patch_count", "unresolved_reason"]
    end

    test "scaffold null_record is NOT populated" do
      refute RequestShape.all_derivation_fields_populated?(RequestShape.null_record())
    end

    test "all three fields populated returns true (honest-empty endpoints [] counts as populated)" do
      record =
        RequestShape.null_record()
        |> Map.put("endpoints", [])
        |> Map.put("body_encoding", "json")
        |> Map.put("content_type", "application/json")

      assert RequestShape.all_derivation_fields_populated?(record)
    end

    test "any single null derivation field returns false" do
      base =
        RequestShape.null_record()
        |> Map.put("endpoints", [])
        |> Map.put("body_encoding", "json")
        |> Map.put("content_type", "application/json")

      for null_key <- RequestShape.derivation_fields() do
        record = Map.put(base, null_key, nil)

        refute RequestShape.all_derivation_fields_populated?(record),
               "expected #{null_key}=nil to return false from populated? predicate"
      end
    end

    test "content_type=nil paired with body_encoding=\"none\" is honest-empty" do
      record =
        RequestShape.null_record()
        |> Map.put("endpoints", [])
        |> Map.put("body_encoding", "none")
        |> Map.put("content_type", nil)

      assert RequestShape.all_derivation_fields_populated?(record),
             "no body → no Content-Type is honest-empty, not unresolved"
    end

    test "content_type=nil with body_encoding != \"none\" is NOT populated" do
      record =
        RequestShape.null_record()
        |> Map.put("endpoints", [])
        |> Map.put("body_encoding", "json")
        |> Map.put("content_type", nil)

      refute RequestShape.all_derivation_fields_populated?(record)
    end

    test "missing key returns false (malformed record safety)" do
      refute RequestShape.all_derivation_fields_populated?(%{})
      refute RequestShape.all_derivation_fields_populated?(%{"endpoints" => []})
    end

    test "non-map input returns false" do
      refute RequestShape.all_derivation_fields_populated?(nil)
      refute RequestShape.all_derivation_fields_populated?([])
      refute RequestShape.all_derivation_fields_populated?("oops")
    end
  end

  describe "content_type_for/1" do
    test "json → application/json" do
      assert RequestShape.content_type_for("json") == "application/json"
    end

    test "form_urlencoded → application/x-www-form-urlencoded" do
      assert RequestShape.content_type_for("form_urlencoded") == "application/x-www-form-urlencoded"
    end

    test "none → nil (no body, no Content-Type)" do
      assert RequestShape.content_type_for("none") == nil
    end

    test "query_string → nil (forward-compat slot)" do
      assert RequestShape.content_type_for("query_string") == nil
    end

    test "unknown / nil → nil" do
      assert RequestShape.content_type_for(nil) == nil
      assert RequestShape.content_type_for("bogus") == nil
    end
  end

  describe "VerbPath.extract_path_params/1" do
    test "no placeholders → empty list" do
      assert VerbPath.extract_path_params("account/balance") == []
    end

    test "single placeholder" do
      assert VerbPath.extract_path_params("orders/{order_id}") == [
               %{"name" => "order_id", "source" => "params"}
             ]
    end

    test "multiple placeholders preserve left-to-right order" do
      assert VerbPath.extract_path_params("trade/{symbol}/orders/{order_id}") == [
               %{"name" => "symbol", "source" => "params"},
               %{"name" => "order_id", "source" => "params"}
             ]
    end

    test "non-string input → empty list" do
      assert VerbPath.extract_path_params(nil) == []
      assert VerbPath.extract_path_params(123) == []
    end
  end

  describe "VerbPath.derive/2" do
    test "no describe_api → {:error, no_describe_api}" do
      assert VerbPath.derive(nil, "private") == {:error, "no_describe_api"}
      assert VerbPath.derive("not a map", "private") == {:error, "no_describe_api"}
    end

    test "section not in describe.api → {:error, section_not_in_api}" do
      api = %{"public" => %{"get" => %{"ticker" => 1}}}
      assert VerbPath.derive(api, "private") == {:error, "section_not_in_api"}
    end

    test "flat section with one HTTP-method leaf" do
      api = %{"private" => %{"get" => %{"account/balance" => 5, "orders/{order_id}" => 1}}}
      {:ok, endpoints} = VerbPath.derive(api, "private")

      assert length(endpoints) == 2

      assert %{
               "http_verb" => "GET",
               "path_template" => "account/balance",
               "path_params" => []
             } in endpoints

      assert %{
               "http_verb" => "GET",
               "path_template" => "orders/{order_id}",
               "path_params" => [%{"name" => "order_id", "source" => "params"}]
             } in endpoints
    end

    test "section with multiple HTTP verbs" do
      api = %{
        "private" => %{
          "get" => %{"balance" => 1},
          "post" => %{"order" => 1},
          "delete" => %{"order/{id}" => 1}
        }
      }

      {:ok, endpoints} = VerbPath.derive(api, "private")

      verbs = endpoints |> Enum.map(& &1["http_verb"]) |> Enum.sort()
      assert verbs == ["DELETE", "GET", "POST"]
    end

    test "nested section walks recursively (gate-style)" do
      api = %{
        "private" => %{
          "spot" => %{"get" => %{"accounts" => 1}},
          "futures" => %{"post" => %{"orders" => 1}}
        }
      }

      {:ok, endpoints} = VerbPath.derive(api, "private")

      assert length(endpoints) == 2
      paths = endpoints |> Enum.map(& &1["path_template"]) |> Enum.sort()
      assert paths == ["accounts", "orders"]
    end

    test "dotted section name resolves via describe.api walk (htx-style)" do
      api = %{
        "spot" => %{
          "private" => %{"get" => %{"v1/accounts" => 1}},
          "public" => %{"get" => %{"v1/symbols" => 1}}
        }
      }

      {:ok, endpoints} = VerbPath.derive(api, "spot.private")

      assert endpoints == [
               %{
                 "http_verb" => "GET",
                 "path_template" => "v1/accounts",
                 "path_params" => []
               }
             ]
    end

    test "list-form HTTP-method entries (legacy CCXT shape)" do
      api = %{"private" => %{"get" => ["account/{id}", "orders"]}}
      {:ok, endpoints} = VerbPath.derive(api, "private")

      paths = endpoints |> Enum.map(& &1["path_template"]) |> Enum.sort()
      assert paths == ["account/{id}", "orders"]
    end

    test "section with no HTTP-method leaves → honest-empty []" do
      api = %{"private" => %{"sub" => %{"deep" => %{"nope" => true}}}}
      assert VerbPath.derive(api, "private") == {:ok, []}
    end

    test "uppercases method keys to RFC 7231 verbs" do
      api = %{"private" => %{"get" => %{"x" => 1}, "post" => %{"y" => 1}, "patch" => %{"z" => 1}}}
      {:ok, endpoints} = VerbPath.derive(api, "private")

      for endpoint <- endpoints do
        assert endpoint["http_verb"] in ["GET", "POST", "PATCH"]
      end
    end
  end

  describe "BodyEncoding.derive/1 — body assignments" do
    test "no sign() body stmts → no_sign_method reason, all-nil" do
      assert BodyEncoding.derive(nil) == %{
               body_encoding: nil,
               content_type: nil,
               reason: "no_sign_method"
             }
    end

    test "no body assignment → none / nil" do
      stmts = [
        %{
          "type" => "ExpressionStatement",
          "expression" => %{
            "type" => "AssignmentExpression",
            "operator" => "=",
            "left" => %{"type" => "Identifier", "name" => "url"},
            "right" => %{"type" => "Literal", "value" => "/api"}
          }
        }
      ]

      assert BodyEncoding.derive(stmts) == %{
               body_encoding: "none",
               content_type: nil,
               reason: nil
             }
    end

    test "body = this.json(...) → json + application/json fallback" do
      stmts = [body_assignment(json_call())]

      assert BodyEncoding.derive(stmts) == %{
               body_encoding: "json",
               content_type: "application/json",
               reason: nil
             }
    end

    test "body = this.urlencode(...) → form_urlencoded + canonical Content-Type" do
      stmts = [body_assignment(urlencode_call("urlencode"))]

      assert BodyEncoding.derive(stmts) == %{
               body_encoding: "form_urlencoded",
               content_type: "application/x-www-form-urlencoded",
               reason: nil
             }
    end

    test "body = this.urlencodeNested(...) → form_urlencoded" do
      stmts = [body_assignment(urlencode_call("urlencodeNested"))]
      assert BodyEncoding.derive(stmts).body_encoding == "form_urlencoded"
    end

    test "body = this.rawencode(...) → form_urlencoded" do
      stmts = [body_assignment(urlencode_call("rawencode"))]
      assert BodyEncoding.derive(stmts).body_encoding == "form_urlencoded"
    end

    test "body = '' (empty literal) → none" do
      stmts = [body_assignment(%{"type" => "Literal", "value" => ""})]
      assert BodyEncoding.derive(stmts).body_encoding == "none"
    end

    test "body = json AND body = urlencode → ambiguous_body" do
      stmts = [
        body_assignment(json_call()),
        body_assignment(urlencode_call("urlencode"))
      ]

      assert BodyEncoding.derive(stmts) == %{
               body_encoding: nil,
               content_type: nil,
               reason: "ambiguous_body"
             }
    end

    test "body = unknown identifier → ambiguous_body" do
      stmts = [body_assignment(%{"type" => "Identifier", "name" => "result"})]
      assert BodyEncoding.derive(stmts).reason == "ambiguous_body"
    end

    test "duplicate same-encoder body assignments → not ambiguous" do
      stmts = [body_assignment(json_call()), body_assignment(json_call())]
      assert BodyEncoding.derive(stmts).body_encoding == "json"
    end

    test "ConditionalExpression body with same encoder both branches" do
      cond_expr = %{
        "type" => "ConditionalExpression",
        "consequent" => json_call(),
        "alternate" => json_call()
      }

      stmts = [body_assignment(cond_expr)]
      assert BodyEncoding.derive(stmts).body_encoding == "json"
    end
  end

  describe "BodyEncoding.derive/1 — Content-Type literal extraction" do
    test "literal Content-Type in headers ObjectExpression overrides canonical" do
      headers_assign = %{
        "type" => "ExpressionStatement",
        "expression" => %{
          "type" => "AssignmentExpression",
          "operator" => "=",
          "left" => %{"type" => "Identifier", "name" => "headers"},
          "right" => %{
            "type" => "ObjectExpression",
            "properties" => [
              %{
                "type" => "Property",
                "key" => %{"type" => "Literal", "value" => "Content-Type"},
                "value" => %{"type" => "Literal", "value" => "application/x-bespoke"}
              }
            ]
          }
        }
      }

      stmts = [body_assignment(json_call()), headers_assign]

      assert BodyEncoding.derive(stmts) == %{
               body_encoding: "json",
               content_type: "application/x-bespoke",
               reason: nil
             }
    end

    test "computed-member Content-Type assignment overrides canonical" do
      headers_assign = %{
        "type" => "ExpressionStatement",
        "expression" => %{
          "type" => "AssignmentExpression",
          "operator" => "=",
          "left" => %{
            "type" => "MemberExpression",
            "computed" => true,
            "object" => %{"type" => "Identifier", "name" => "headers"},
            "property" => %{"type" => "Literal", "value" => "Content-Type"}
          },
          "right" => %{"type" => "Literal", "value" => "text/plain"}
        }
      }

      stmts = [body_assignment(json_call()), headers_assign]
      assert BodyEncoding.derive(stmts).content_type == "text/plain"
    end

    test "case-insensitive Content-Type key match" do
      headers_assign = %{
        "type" => "ExpressionStatement",
        "expression" => %{
          "type" => "AssignmentExpression",
          "operator" => "=",
          "left" => %{
            "type" => "MemberExpression",
            "computed" => true,
            "object" => %{"type" => "Identifier", "name" => "headers"},
            "property" => %{"type" => "Literal", "value" => "content-type"}
          },
          "right" => %{"type" => "Literal", "value" => "application/json"}
        }
      }

      stmts = [body_assignment(json_call()), headers_assign]
      assert BodyEncoding.derive(stmts).content_type == "application/json"
    end
  end

  describe "Derive.derive/3 — orchestrator + biconditional" do
    test "no auth_sections → empty map" do
      assert Derive.derive(nil, nil, nil) == %{}
      assert Derive.derive(nil, [], nil) == %{}
    end

    test "no sign_method but auth_sections present → no_sign_method reason, endpoints derived" do
      describe_api = %{"private" => %{"get" => %{"x" => 1}}}
      result = Derive.derive(nil, ["private"], describe_api)

      record = result["private"]
      assert record["unresolved_reason"] == "no_sign_method"
      # Endpoints stay populated (Honesty-Rule: derive what we can).
      assert is_list(record["endpoints"])
      assert length(record["endpoints"]) == 1
      # Body fields nulled by terminal sign-method-absent reason.
      assert record["body_encoding"] == nil
      assert record["content_type"] == nil
    end

    test "section_not_in_api short-circuits the whole record" do
      describe_api = %{"public" => %{"get" => %{"x" => 1}}}
      sign = sign_method([body_assignment(json_call())])

      result = Derive.derive(sign, ["private"], describe_api)
      record = result["private"]

      assert record["unresolved_reason"] == "section_not_in_api"
      assert record["endpoints"] == nil
      assert record["body_encoding"] == nil
      assert record["content_type"] == nil
    end

    test "no_describe_api short-circuits the whole record" do
      sign = sign_method([body_assignment(json_call())])

      result = Derive.derive(sign, ["private"], nil)
      record = result["private"]

      assert record["unresolved_reason"] == "no_describe_api"
      assert record["endpoints"] == nil
    end

    test "ambiguous_body keeps endpoints but nulls body fields" do
      describe_api = %{"private" => %{"get" => %{"x" => 1}}}

      sign =
        sign_method([
          body_assignment(json_call()),
          body_assignment(urlencode_call("urlencode"))
        ])

      result = Derive.derive(sign, ["private"], describe_api)
      record = result["private"]

      assert record["unresolved_reason"] == "ambiguous_body"
      assert is_list(record["endpoints"])
      assert record["body_encoding"] == nil
      assert record["content_type"] == nil
    end

    test "fully-derived record flips unresolved_reason to nil (biconditional)" do
      describe_api = %{"private" => %{"get" => %{"x" => 1}, "post" => %{"y" => 1}}}
      sign = sign_method([body_assignment(json_call())])

      result = Derive.derive(sign, ["private"], describe_api)
      record = result["private"]

      assert record["unresolved_reason"] == nil
      assert record["body_encoding"] == "json"
      assert record["content_type"] == "application/json"
      assert is_list(record["endpoints"])
      assert length(record["endpoints"]) == 2
    end

    test "no-body record (body_encoding=none + content_type=nil) flips biconditional cleanly" do
      describe_api = %{"private" => %{"get" => %{"ping" => 1}}}
      # sign() with no body assignments anywhere
      sign = sign_method([])

      result = Derive.derive(sign, ["private"], describe_api)
      record = result["private"]

      assert record["body_encoding"] == "none"
      assert record["content_type"] == nil
      # Biconditional flips: content_type=nil paired with body_encoding=none
      # is honest-empty per all_derivation_fields_populated?/1.
      assert record["unresolved_reason"] == nil
    end

    test "every authenticated section gets a record (parity with auth_sections)" do
      describe_api = %{
        "private" => %{"get" => %{"a" => 1}},
        "sapi" => %{"post" => %{"b" => 1}}
      }

      sign = sign_method([body_assignment(json_call())])

      result = Derive.derive(sign, ["private", "sapi"], describe_api)

      assert result |> Map.keys() |> Enum.sort() == ["private", "sapi"]
    end
  end

  # --- Test fixtures ---

  defp body_assignment(rhs) do
    %{
      "type" => "ExpressionStatement",
      "expression" => %{
        "type" => "AssignmentExpression",
        "operator" => "=",
        "left" => %{"type" => "Identifier", "name" => "body"},
        "right" => rhs
      }
    }
  end

  defp json_call do
    %{
      "type" => "CallExpression",
      "callee" => %{
        "type" => "MemberExpression",
        "object" => %{"type" => "ThisExpression"},
        "property" => %{"type" => "Identifier", "name" => "json"}
      },
      "arguments" => []
    }
  end

  defp urlencode_call(name) do
    %{
      "type" => "CallExpression",
      "callee" => %{
        "type" => "MemberExpression",
        "object" => %{"type" => "ThisExpression"},
        "property" => %{"type" => "Identifier", "name" => name}
      },
      "arguments" => []
    }
  end

  defp sign_method(body_stmts) do
    %{"body" => %{"body" => body_stmts}}
  end
end

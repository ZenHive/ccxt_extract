defmodule CcxtExtract.Normalization.BalanceTest do
  @moduledoc """
  Unit tests for `CcxtExtract.Normalization.Balance` — the Task 77 derivation
  that populates `field_maps["balance"]` from a per-exchange `parse_methods.json`
  entry.

  Synthetic AST fixtures only — no file I/O. Corpus-level shape assertions
  live in `test/integration/cached/schema_v4_emit_cached_test.exs`.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Normalization.Balance

  # --- AST builder helpers ---

  defp identifier(name), do: %{"type" => "Identifier", "name" => name}
  defp literal(value), do: %{"type" => "Literal", "value" => value}

  defp this_call(method, args) do
    %{
      "type" => "CallExpression",
      "callee" => %{
        "type" => "MemberExpression",
        "object" => %{"type" => "ThisExpression"},
        "property" => identifier(method)
      },
      "arguments" => args
    }
  end

  # VariableDeclaration: `const <name> = <init>;`
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

  # ExpressionStatement with AssignmentExpression: `account['<field>'] = <rhs>`
  defp account_assign(field, rhs) do
    %{
      "type" => "ExpressionStatement",
      "expression" => %{
        "type" => "AssignmentExpression",
        "operator" => "=",
        "left" => %{
          "type" => "MemberExpression",
          "computed" => true,
          "object" => identifier("account"),
          "property" => literal(field)
        },
        "right" => rhs
      }
    }
  end

  # `return this.safeBalance(result);`
  defp safe_balance_return do
    %{
      "type" => "ReturnStatement",
      "argument" => this_call("safeBalance", [identifier("result")])
    }
  end

  # Wrap statements into a parse_methods entry for `parseBalance`.
  defp wrap_entry(stmts) do
    %{
      "parse_methods" => %{
        "parseBalance" => %{
          "body" => %{"type" => "BlockStatement", "body" => stmts}
        }
      }
    }
  end

  # ---------------------------------------------------------------------------
  # Nil / absent-entry guards
  # ---------------------------------------------------------------------------

  describe "derive/1 — nil / missing parseBalance" do
    test "returns nil when entry is nil" do
      assert Balance.derive(nil) == nil
    end

    test "returns nil when parse_methods does not contain parseBalance" do
      entry = %{"parse_methods" => %{"parseTrade" => %{}}}
      assert Balance.derive(entry) == nil
    end

    test "returns nil for non-map input" do
      assert Balance.derive("not a map") == nil
      assert Balance.derive(42) == nil
      assert Balance.derive([]) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Unresolved-reason paths
  # ---------------------------------------------------------------------------

  describe "derive/1 — unresolved paths" do
    test "no return statement emits _unresolved_reason: no_return_statement" do
      result = Balance.derive(wrap_entry([]))
      assert result["_unresolved_reason"] == "no_return_statement"
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
      assert result["extras"] == []
    end

    test "non-safeBalance return emits _unresolved_reason with callee name" do
      ret = %{
        "type" => "ReturnStatement",
        "argument" => this_call("parseAccountBalance", [identifier("result")])
      }

      result = Balance.derive(wrap_entry([ret]))
      assert result["_unresolved_reason"] =~ "non_safe_balance_return:parseAccountBalance"
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
    end
  end

  # ---------------------------------------------------------------------------
  # Output shape contract
  # ---------------------------------------------------------------------------

  describe "derive/1 — output shape contract" do
    test "all 7 unified fields appear as keys in field_map (even when nil)" do
      result = Balance.derive(wrap_entry([safe_balance_return()]))

      assert result["field_map"] |> Map.keys() |> Enum.sort() ==
               Enum.sort(Balance.unified_fields())
    end

    test "_unresolved_reason is nil when safeBalance return found" do
      result = Balance.derive(wrap_entry([safe_balance_return()]))
      assert result["_unresolved_reason"] == nil
    end

    test "field_map has 7 entries" do
      result = Balance.derive(wrap_entry([safe_balance_return()]))
      assert map_size(result["field_map"]) == 7
    end

    test "extras is always empty for balance (no ObjectExpression to scan)" do
      result = Balance.derive(wrap_entry([safe_balance_return()]))
      assert result["extras"] == []
    end
  end

  # ---------------------------------------------------------------------------
  # Structurally-null fields
  # ---------------------------------------------------------------------------

  describe "derive/1 — structurally-null fields" do
    test "info is always nil (raw pass-through, not a safe-call)" do
      result = Balance.derive(wrap_entry([safe_balance_return()]))
      assert result["field_map"]["info"] == nil
    end

    test "datetime is always nil (derived from timestamp via iso8601)" do
      result = Balance.derive(wrap_entry([safe_balance_return()]))
      assert result["field_map"]["datetime"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Per-currency field assignments (free / used / total / debt)
  # ---------------------------------------------------------------------------

  describe "derive/1 — per-currency field assignments" do
    test "account['free'] = this.safeString(balance, 'cash') populates free slot" do
      stmts = [
        account_assign("free", this_call("safeString", [identifier("balance"), literal("cash")])),
        safe_balance_return()
      ]

      result = Balance.derive(wrap_entry(stmts))
      slot = result["field_map"]["free"]
      assert slot["key"] == "cash"
      assert slot["coercion"] == "safeString"
      assert slot["format"] == nil
    end

    test "account['used'] = this.safeString2(balance, 'usedAmt', 'used') populates used slot" do
      stmts = [
        account_assign(
          "used",
          this_call("safeString2", [identifier("balance"), literal("usedAmt"), literal("used")])
        ),
        safe_balance_return()
      ]

      result = Balance.derive(wrap_entry(stmts))
      slot = result["field_map"]["used"]
      assert slot["key"] == "usedAmt"
      assert slot["coercion"] == "safeString2"
    end

    test "account['total'] = this.safeNumber(balance, 'totalBalance') populates total slot" do
      stmts = [
        account_assign(
          "total",
          this_call("safeNumber", [identifier("balance"), literal("totalBalance")])
        ),
        safe_balance_return()
      ]

      result = Balance.derive(wrap_entry(stmts))
      slot = result["field_map"]["total"]
      assert slot["key"] == "totalBalance"
      assert slot["coercion"] == "safeNumber"
    end

    test "account['debt'] = this.safeString(balance, 'debt') populates debt slot" do
      stmts = [
        account_assign("debt", this_call("safeString", [identifier("balance"), literal("debt")])),
        safe_balance_return()
      ]

      result = Balance.derive(wrap_entry(stmts))
      slot = result["field_map"]["debt"]
      assert slot["key"] == "debt"
      assert slot["coercion"] == "safeString"
    end

    test "missing per-currency field emits nil slot" do
      result = Balance.derive(wrap_entry([safe_balance_return()]))
      assert result["field_map"]["free"] == nil
      assert result["field_map"]["used"] == nil
      assert result["field_map"]["total"] == nil
      assert result["field_map"]["debt"] == nil
    end

    test "balance['free'] = X (non-account object) is NOT classified as a balance slot" do
      # LHS object is `balance`, not `account` — must not be collected.
      non_account_assign = %{
        "type" => "ExpressionStatement",
        "expression" => %{
          "type" => "AssignmentExpression",
          "operator" => "=",
          "left" => %{
            "type" => "MemberExpression",
            "computed" => true,
            "object" => identifier("balance"),
            "property" => literal("free")
          },
          "right" => this_call("safeString", [identifier("balance"), literal("cash")])
        }
      }

      result = Balance.derive(wrap_entry([non_account_assign, safe_balance_return()]))
      assert result["field_map"]["free"] == nil
    end

    test "account['free'] = X (correct account object) IS classified as a balance slot" do
      stmts = [
        account_assign("free", this_call("safeString", [identifier("balance"), literal("cash")])),
        safe_balance_return()
      ]

      result = Balance.derive(wrap_entry(stmts))
      assert result["field_map"]["free"]["key"] == "cash"
    end

    test "out-of-vocab coercion on a field emits nil for that slot" do
      # stringAdd is outside the closed vocab
      stmts = [
        account_assign(
          "total",
          this_call("stringAdd", [identifier("balance"), literal("totalBalance")])
        ),
        safe_balance_return()
      ]

      result = Balance.derive(wrap_entry(stmts))
      assert result["field_map"]["total"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Assignments inside loop bodies
  # ---------------------------------------------------------------------------

  describe "derive/1 — assignments inside loop bodies" do
    test "account['free'] assignment inside a ForInStatement body is collected" do
      for_in = %{
        "type" => "ForInStatement",
        "left" => var_decl("currency", nil),
        "right" => identifier("balances"),
        "body" => %{
          "type" => "BlockStatement",
          "body" => [
            account_assign(
              "free",
              this_call("safeString", [identifier("balance"), literal("free")])
            )
          ]
        }
      }

      result = Balance.derive(wrap_entry([for_in, safe_balance_return()]))
      slot = result["field_map"]["free"]
      assert slot["key"] == "free"
      assert slot["coercion"] == "safeString"
    end

    test "account['used'] assignment inside a ForStatement body is collected" do
      for_stmt = %{
        "type" => "ForStatement",
        "init" => nil,
        "test" => nil,
        "update" => nil,
        "body" => %{
          "type" => "BlockStatement",
          "body" => [
            account_assign(
              "used",
              this_call("safeString", [identifier("balance"), literal("locked")])
            )
          ]
        }
      }

      result = Balance.derive(wrap_entry([for_stmt, safe_balance_return()]))
      slot = result["field_map"]["used"]
      assert slot["key"] == "locked"
      assert slot["coercion"] == "safeString"
    end
  end

  # ---------------------------------------------------------------------------
  # Timestamp field (top-level binding)
  # ---------------------------------------------------------------------------

  describe "derive/1 — timestamp field" do
    test "const timestamp = this.safeInteger(response, 'ts') populates timestamp slot" do
      stmts = [
        var_decl("timestamp", this_call("safeInteger", [identifier("response"), literal("ts")])),
        safe_balance_return()
      ]

      result = Balance.derive(wrap_entry(stmts))
      ts = result["field_map"]["timestamp"]
      assert ts["key"] == "ts"
      assert ts["coercion"] == "safeInteger"
      assert ts["format"] == "ms"
    end

    test "const timestamp = this.safeTimestamp(response, 'time') emits format: s" do
      stmts = [
        var_decl(
          "timestamp",
          this_call("safeTimestamp", [identifier("response"), literal("time")])
        ),
        safe_balance_return()
      ]

      result = Balance.derive(wrap_entry(stmts))
      ts = result["field_map"]["timestamp"]
      assert ts["coercion"] == "safeTimestamp"
      assert ts["format"] == "s"
    end

    test "no timestamp binding emits nil for timestamp" do
      result = Balance.derive(wrap_entry([safe_balance_return()]))
      assert result["field_map"]["timestamp"] == nil
    end
  end
end

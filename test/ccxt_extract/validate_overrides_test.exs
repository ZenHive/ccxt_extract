defmodule CcxtExtract.ValidateOverridesTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.ValidateOverrides

  @describe_entry %{
    "path" => "/structure/authenticated_sections",
    "value" => ["private"],
    "reason" => "test override"
  }

  setup do
    tmp = Path.join(System.tmp_dir!(), "validate_overrides_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "describe"))
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  describe "run/1" do
    test "verified when derive empty and sections reachable", %{tmp: tmp} do
      id = "probe_ok"
      write_override(tmp, id, [@describe_entry])
      write_sign_methods(tmp, id, nil)
      write_describe(tmp, id, %{"api" => %{"private" => %{}, "public" => %{}}})

      assert {:ok, report} =
               ValidateOverrides.run(
                 discoveries_dir: tmp,
                 overrides_dir: Path.join(tmp, "overrides"),
                 exchange_ids: [id]
               )

      [entry] = exchange_entries(report, id)
      assert entry["status"] == "verified"
      assert entry["probe"] == "authenticated_sections"
    end

    test "warning when override matches AST derivation", %{tmp: tmp} do
      id = "redundant"
      sign = minimal_sign_with_check()

      write_override(tmp, id, [
        Map.put(@describe_entry, "value", ["private"])
      ])

      write_sign_methods(tmp, id, sign)
      write_describe(tmp, id, %{"api" => %{"private" => %{"get" => %{}}, "public" => %{}}})

      assert {:ok, report} =
               ValidateOverrides.run(
                 discoveries_dir: tmp,
                 overrides_dir: Path.join(tmp, "overrides"),
                 exchange_ids: [id]
               )

      [entry] = exchange_entries(report, id)
      assert entry["status"] == "warning"
      assert entry["reason"] == "override_redundant_ast_now_derives_same"
    end

    test "verified for curated subset removing AST false positive", %{tmp: tmp} do
      id = "subset"
      # Walker derives private + bogus; override keeps only private.
      sign = sign_with_private_and_bogus_checks()

      write_override(tmp, id, [
        Map.put(@describe_entry, "value", ["private"])
      ])

      write_sign_methods(tmp, id, sign)
      write_describe(tmp, id, %{"api" => %{"private" => %{}, "public" => %{}}})

      assert {:ok, report} =
               ValidateOverrides.run(
                 discoveries_dir: tmp,
                 overrides_dir: Path.join(tmp, "overrides"),
                 exchange_ids: [id]
               )

      [entry] = exchange_entries(report, id)
      assert entry["status"] == "verified"
    end

    test "mismatch when override sections unreachable", %{tmp: tmp} do
      id = "bad_reach"
      write_override(tmp, id, [Map.put(@describe_entry, "value", ["nonexistent_section"])])
      write_sign_methods(tmp, id, nil)
      write_describe(tmp, id, %{"api" => %{"public" => %{}}})

      assert {:ok, report} =
               ValidateOverrides.run(
                 discoveries_dir: tmp,
                 overrides_dir: Path.join(tmp, "overrides"),
                 exchange_ids: [id]
               )

      [entry] = exchange_entries(report, id)
      assert entry["status"] == "mismatch"
    end

    test "unverified when describe discovery is missing", %{tmp: tmp} do
      id = "no_describe"
      write_override(tmp, id, [@describe_entry])
      write_sign_methods(tmp, id, nil)
      # describe file deliberately not written

      assert {:ok, report} =
               ValidateOverrides.run(
                 discoveries_dir: tmp,
                 overrides_dir: Path.join(tmp, "overrides"),
                 exchange_ids: [id]
               )

      [entry] = exchange_entries(report, id)
      assert entry["status"] == "unverified"
      assert entry["reason"] == "no_describe_discovery"
    end

    test "unverified for explicit unverified flag", %{tmp: tmp} do
      id = "flagged"
      entry = Map.put(@describe_entry, "unverified", true)
      write_override(tmp, id, [entry])

      assert {:ok, report} =
               ValidateOverrides.run(
                 discoveries_dir: tmp,
                 overrides_dir: Path.join(tmp, "overrides"),
                 exchange_ids: [id]
               )

      [entry] = exchange_entries(report, id)
      assert entry["status"] == "unverified"
      assert entry["probe"] == "explicit_flag"
      assert entry["explicit_unverified"] == true
    end

    test "url_templates probe verifies matching runtime", %{tmp: tmp} do
      id = "url_ok"
      runtime = %{"public" => %{"url_prefix" => "https://example.com/"}}

      write_override(tmp, id, [
        %{
          "path" => "/runtime/url_templates",
          "value" => runtime,
          "reason" => "test"
        }
      ])

      write_url_templates(tmp, id, runtime)

      assert {:ok, report} =
               ValidateOverrides.run(
                 discoveries_dir: tmp,
                 overrides_dir: Path.join(tmp, "overrides"),
                 exchange_ids: [id]
               )

      [entry] = exchange_entries(report, id)
      assert entry["status"] == "verified"
      assert entry["probe"] == "url_templates"
    end

    test "error on unsupported pointer segment", %{tmp: tmp} do
      id = "bad_ptr"

      write_override(tmp, id, [
        %{
          "path" => "/structure/sign_recipe/sections/0",
          "value" => "x",
          "reason" => "array index not supported yet"
        }
      ])

      assert {:ok, report} =
               ValidateOverrides.run(
                 discoveries_dir: tmp,
                 overrides_dir: Path.join(tmp, "overrides"),
                 exchange_ids: [id]
               )

      [entry] = exchange_entries(report, id)
      assert entry["status"] == "error"
      assert entry["probe"] == "pointer"
    end
  end

  describe "strict_failure?/1" do
    test "true on mismatch and explicit unverified" do
      report = %{
        "exchanges" => [
          %{
            "entries" => [
              %{"status" => "mismatch", "explicit_unverified" => false},
              %{"status" => "unverified", "explicit_unverified" => true},
              %{"status" => "unverified", "explicit_unverified" => false, "reason" => "no_probe_for_path"}
            ]
          }
        ]
      }

      assert ValidateOverrides.strict_failure?(report)
    end

    test "false when only informational unverified" do
      report = %{
        "exchanges" => [
          %{
            "entries" => [
              %{"status" => "unverified", "explicit_unverified" => false}
            ]
          }
        ]
      }

      refute ValidateOverrides.strict_failure?(report)
    end
  end

  # --- fixtures ---

  defp exchange_entries(report, id) do
    report["exchanges"]
    |> Enum.find(&(&1["exchange"] == id))
    |> Map.fetch!("entries")
  end

  defp write_override(tmp, id, overrides) do
    dir = Path.join(tmp, "overrides")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "#{id}.json"),
      Jason.encode!(%{"schema_version" => "1", "overrides" => overrides})
    )
  end

  defp write_sign_methods(tmp, id, sign) do
    path = Path.join(tmp, "sign_methods.json")

    data =
      if File.exists?(path) do
        path |> File.read!() |> Jason.decode!()
      else
        %{"exchanges" => []}
      end

    exchanges =
      data["exchanges"]
      |> Enum.reject(&(&1["id"] == id))
      |> then(&[%{"id" => id, "sign" => sign} | &1])

    File.write!(path, Jason.encode!(%{"exchanges" => exchanges}))
  end

  defp write_describe(tmp, id, describe) do
    File.write!(
      Path.join(tmp, "describe/#{id}.json"),
      Jason.encode!(%{"id" => id, "describe" => Map.put(describe, "id", id)})
    )
  end

  defp write_url_templates(tmp, id, templates) do
    path = Path.join(tmp, "url_templates.json")

    File.write!(
      path,
      Jason.encode!(%{
        "exchanges" => [%{"id" => id, "url_templates" => templates}]
      })
    )
  end

  # Minimal sign() body: if (api === 'private') { this.checkRequiredCredentials(); }
  defp minimal_sign_with_check do
    %{
      "body" => %{
        "body" => [
          %{
            "type" => "IfStatement",
            "test" => %{
              "type" => "BinaryExpression",
              "operator" => "===",
              "left" => %{"type" => "Identifier", "name" => "api"},
              "right" => %{"type" => "Literal", "value" => "private"}
            },
            "consequent" => %{
              "type" => "BlockStatement",
              "body" => [check_required_credentials_stmt()]
            },
            "alternate" => nil
          }
        ]
      }
    }
  end

  defp sign_with_private_and_bogus_checks do
    %{
      "body" => %{
        "body" => [
          %{
            "type" => "IfStatement",
            "test" => %{
              "type" => "BinaryExpression",
              "operator" => "===",
              "left" => %{"type" => "Identifier", "name" => "api"},
              "right" => %{"type" => "Literal", "value" => "private"}
            },
            "consequent" => %{
              "type" => "BlockStatement",
              "body" => [check_required_credentials_stmt()]
            },
            "alternate" => nil
          },
          %{
            "type" => "IfStatement",
            "test" => %{
              "type" => "BinaryExpression",
              "operator" => "===",
              "left" => %{"type" => "Identifier", "name" => "api"},
              "right" => %{"type" => "Literal", "value" => "bogus"}
            },
            "consequent" => %{
              "type" => "BlockStatement",
              "body" => [check_required_credentials_stmt()]
            },
            "alternate" => nil
          }
        ]
      }
    }
  end

  defp check_required_credentials_stmt do
    %{
      "type" => "ExpressionStatement",
      "expression" => %{
        "type" => "CallExpression",
        "callee" => %{
          "type" => "MemberExpression",
          "object" => %{"type" => "ThisExpression"},
          "property" => %{"type" => "Identifier", "name" => "checkRequiredCredentials"}
        },
        "arguments" => []
      }
    }
  end
end

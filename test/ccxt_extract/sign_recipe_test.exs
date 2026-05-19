defmodule CcxtExtract.SignRecipeTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.Paths
  alias CcxtExtract.SignRecipe

  @recipe_schema_path "schema/sign_recipe_v1.json"

  describe "null_recipe/0" do
    test "has the nine required keys" do
      recipe = SignRecipe.null_recipe()

      required =
        ~w(crypto_op canonical_string signature_placement auth_headers nonce timestamp pre_sign_transforms unresolved_reason patch_count)

      assert recipe |> Map.keys() |> Enum.sort() == Enum.sort(required)
    end

    test "nulls every derivation field and tags unresolved_reason = not_yet_derived" do
      recipe = SignRecipe.null_recipe()

      for field <- ~w(crypto_op canonical_string signature_placement auth_headers nonce timestamp pre_sign_transforms) do
        assert Map.fetch!(recipe, field) == nil,
               "expected #{field} to start nil in the scaffold"
      end

      assert recipe["unresolved_reason"] == "not_yet_derived"
      assert recipe["patch_count"] == 0
    end

    test "conforms to priv/schema/sign_recipe_v1.json" do
      root = build_recipe_schema_root()
      assert :ok = SignRecipe.null_recipe() |> JSV.validate(root) |> to_ok_or_errors()
    end
  end

  describe "build_default/1" do
    test "returns one null recipe per section" do
      sections = ["private", "sapi", "fapiPrivate"]
      recipe_map = SignRecipe.build_default(sections)

      assert recipe_map |> Map.keys() |> Enum.sort() == Enum.sort(sections)
      assert Enum.all?(recipe_map, fn {_k, v} -> v == SignRecipe.null_recipe() end)
    end

    test "returns an empty map for nil (sign_method absent)" do
      assert SignRecipe.build_default(nil) == %{}
    end

    test "returns an empty map for [] (sign_method present but no auth gates)" do
      assert SignRecipe.build_default([]) == %{}
    end

    test "collapses duplicate section names without raising" do
      recipe_map = SignRecipe.build_default(["private", "private", "sapi"])
      assert recipe_map |> Map.keys() |> Enum.sort() == ["private", "sapi"]
    end

    test "every emitted recipe conforms to sign_recipe_v1.json" do
      root = build_recipe_schema_root()

      recipe_map = SignRecipe.build_default(["private", "sapi"])

      for {_section, recipe} <- recipe_map do
        assert :ok = recipe |> JSV.validate(root) |> to_ok_or_errors()
      end
    end
  end

  describe "derivation_fields/0 and all_derivation_fields_populated?/1 (Task 69)" do
    test "derivation_fields/0 returns the seven populated-by-Phase-10/Task-72 keys" do
      assert SignRecipe.derivation_fields() == [
               "crypto_op",
               "canonical_string",
               "signature_placement",
               "auth_headers",
               "nonce",
               "timestamp",
               "pre_sign_transforms"
             ]
    end

    test "derivation_fields/0 is a strict subset of required_keys/0" do
      assert SignRecipe.derivation_fields() -- SignRecipe.required_keys() == []
      # Required minus derivation = metadata (unresolved_reason + patch_count).
      leftover = SignRecipe.required_keys() -- SignRecipe.derivation_fields()
      assert Enum.sort(leftover) == ["patch_count", "unresolved_reason"]
    end

    test "scaffold null_recipe is NOT populated (every field nil)" do
      refute SignRecipe.all_derivation_fields_populated?(SignRecipe.null_recipe())
    end

    test "all seven fields populated returns true (honest-empty [] counts as populated)" do
      # Empty list for auth_headers / pre_sign_transforms is non-nil,
      # which means "we proved there are zero" — honest-empty, NOT
      # unresolved. Exercising both list fields with [] here covers
      # that semantic inline.
      populated =
        SignRecipe.null_recipe()
        |> Map.put("crypto_op", %{"algo" => "hmac_sha256"})
        |> Map.put("canonical_string", %{})
        |> Map.put("signature_placement", %{"location" => "header", "key" => "X"})
        |> Map.put("auth_headers", [])
        |> Map.put("nonce", %{"source" => "timestamp_ms", "format" => "integer"})
        |> Map.put("timestamp", %{"source" => "timestamp_ms", "format" => "integer"})
        |> Map.put("pre_sign_transforms", [])

      assert SignRecipe.all_derivation_fields_populated?(populated)
    end

    test "any single null field returns false" do
      for null_key <- SignRecipe.derivation_fields() do
        record =
          SignRecipe.null_recipe()
          |> Map.put("crypto_op", %{"algo" => "hmac_sha256"})
          |> Map.put("canonical_string", %{})
          |> Map.put("signature_placement", %{"location" => "header", "key" => "X"})
          |> Map.put("auth_headers", [])
          |> Map.put("nonce", %{"source" => "timestamp_ms", "format" => "integer"})
          |> Map.put("timestamp", %{"source" => "timestamp_ms", "format" => "integer"})
          |> Map.put("pre_sign_transforms", [])
          |> Map.put(null_key, nil)

        refute SignRecipe.all_derivation_fields_populated?(record),
               "expected #{null_key}=nil to return false from populated? predicate"
      end
    end

    test "missing key returns false (malformed record safety)" do
      refute SignRecipe.all_derivation_fields_populated?(%{})
      refute SignRecipe.all_derivation_fields_populated?(%{"crypto_op" => %{}})
    end

    test "non-map input returns false" do
      refute SignRecipe.all_derivation_fields_populated?(nil)
      refute SignRecipe.all_derivation_fields_populated?([])
      refute SignRecipe.all_derivation_fields_populated?("oops")
    end
  end

  describe "terminal_reasons/0 and terminal_reason?/1" do
    test "terminal_reasons/0 returns the three short-circuit tags (excludes not_yet_derived)" do
      assert Enum.sort(SignRecipe.terminal_reasons()) ==
               ~w(ambiguous_ast custom_signing_family no_sign_method)

      # Defensive: not_yet_derived is the SCAFFOLD default and must never
      # be treated as terminal — derivation modules need to keep filling
      # fields when they encounter it.
      refute "not_yet_derived" in SignRecipe.terminal_reasons()
    end

    test "terminal_reason?/1 returns true for every terminal tag" do
      for reason <- SignRecipe.terminal_reasons() do
        assert SignRecipe.terminal_reason?(reason),
               "expected terminal_reason?(#{inspect(reason)}) to be true"
      end
    end

    test "terminal_reason?/1 returns false for not_yet_derived (scaffold default)" do
      refute SignRecipe.terminal_reason?("not_yet_derived")
    end

    test "terminal_reason?/1 returns false for nil and non-binary input" do
      refute SignRecipe.terminal_reason?(nil)
      refute SignRecipe.terminal_reason?(:atom_reason)
      refute SignRecipe.terminal_reason?(42)
      refute SignRecipe.terminal_reason?(%{"reason" => "x"})
    end

    test "terminal_reason?/1 returns false for unknown binary tags" do
      refute SignRecipe.terminal_reason?("totally_made_up_tag")
      refute SignRecipe.terminal_reason?("")
    end
  end

  defp build_recipe_schema_root do
    @recipe_schema_path
    |> read_schema!()
    |> JSV.build!()
  end

  defp read_schema!(rel) do
    rel |> Paths.priv() |> File.read!() |> Jason.decode!()
  end

  defp to_ok_or_errors({:ok, _}), do: :ok
  defp to_ok_or_errors({:error, errors}), do: {:error, errors}
end

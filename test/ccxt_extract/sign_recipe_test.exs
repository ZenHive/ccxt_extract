defmodule CcxtExtract.SignRecipeTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.Paths
  alias CcxtExtract.SignRecipe

  @recipe_schema_path "schema/sign_recipe_v1.json"

  describe "null_recipe/0" do
    test "has the eight required keys" do
      recipe = SignRecipe.null_recipe()

      required =
        ~w(crypto_op canonical_string signature_placement auth_headers nonce pre_sign_transforms unresolved_reason patch_count)

      assert recipe |> Map.keys() |> Enum.sort() == Enum.sort(required)
    end

    test "nulls every derivation field and tags unresolved_reason = not_yet_derived" do
      recipe = SignRecipe.null_recipe()

      for field <- ~w(crypto_op canonical_string signature_placement auth_headers nonce pre_sign_transforms) do
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
    test "derivation_fields/0 returns the six populated-by-Phase-10 keys" do
      assert SignRecipe.derivation_fields() == [
               "crypto_op",
               "canonical_string",
               "signature_placement",
               "auth_headers",
               "nonce",
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

    test "all six fields populated returns true (honest-empty [] counts as populated)" do
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

  describe "exchange_v3.json parity" do
    test "SignRecipeRecord in exchange_v3.json matches sign_recipe_v1.json" do
      standalone = read_schema!(@recipe_schema_path)
      exchange_schema = read_schema!("schema/exchange_v3.json")
      inline = get_in(exchange_schema, ["$defs", "SignRecipeRecord"])

      assert inline != nil, "exchange_v3.json must define $defs.SignRecipeRecord"

      # The two schemas may carry different descriptions (one is standalone,
      # one is inside the exchange schema), but the validation-relevant
      # fields must match.
      for key <- ~w(additionalProperties required type) do
        assert inline[key] == standalone[key],
               "SignRecipeRecord.#{key} drift: exchange_v3.json has #{inspect(inline[key])} but sign_recipe_v1.json has #{inspect(standalone[key])}"
      end

      # Enum tables inside properties must also match. The standalone uses
      # `#/$defs/<Name>` refs while the exchange version uses
      # `#/$defs/SignRecipe<Name>` refs — walk each property and compare the
      # concrete leaf schemas after resolving one hop.
      standalone_props = Map.fetch!(standalone, "properties")
      inline_props = Map.fetch!(inline, "properties")

      assert standalone_props |> Map.keys() |> Enum.sort() ==
               inline_props |> Map.keys() |> Enum.sort()

      assert_enum_parity(standalone_props, inline_props, "unresolved_reason")
      assert_integer_parity(standalone_props, inline_props, "patch_count")

      # Every sub-def's enum (CryptoOp.algo, CanonicalString.family, etc.)
      # must match between the two schemas. Prevents silent drift in the
      # vocabularies populated by Tasks 65–69.
      assert_subdef_enum_parity(standalone, exchange_schema)
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

  defp assert_enum_parity(standalone_props, inline_props, key) do
    standalone_enum =
      standalone_props
      |> get_in([key, "oneOf"])
      |> Enum.find_value(&Map.get(&1, "enum"))
      |> Enum.sort()

    inline_enum =
      inline_props
      |> get_in([key, "oneOf"])
      |> Enum.find_value(&Map.get(&1, "enum"))
      |> Enum.sort()

    assert standalone_enum == inline_enum, "enum drift at #{key}"
  end

  defp assert_integer_parity(standalone_props, inline_props, key) do
    assert standalone_props[key]["type"] == inline_props[key]["type"]
    assert standalone_props[key]["minimum"] == inline_props[key]["minimum"]
  end

  # Enum-carrying properties inside SignRecipe sub-defs. The left half is
  # the def name in `sign_recipe_v1.json`, the right half is the
  # `SignRecipe`-prefixed name in `exchange_v3.json`. A trailing list of
  # property paths names the enum-bearing leaves to compare.
  @subdef_enum_paths [
    {"CryptoOp", "SignRecipeCryptoOp", ["algo"]},
    {"CanonicalString", "SignRecipeCanonicalString", ["family", "encoding"]},
    {"CanonicalComponent", "SignRecipeCanonicalComponent", ["source"]},
    {"SignaturePlacement", "SignRecipeSignaturePlacement", ["location"]},
    {"AuthHeader", "SignRecipeAuthHeader", ["source"]},
    {"Nonce", "SignRecipeNonce", ["source", "format"]},
    {"PreSignTransform", "SignRecipePreSignTransform", ["op", "target"]}
  ]

  defp assert_subdef_enum_parity(standalone, exchange_schema) do
    for {standalone_def, exchange_def, props} <- @subdef_enum_paths,
        prop <- props do
      standalone_enum = get_in(standalone, ["$defs", standalone_def, "properties", prop, "enum"])
      inline_enum = get_in(exchange_schema, ["$defs", exchange_def, "properties", prop, "enum"])

      assert is_list(standalone_enum) and is_list(inline_enum),
             "expected enum at $defs.#{standalone_def}.properties.#{prop} in both schemas"

      assert Enum.sort(standalone_enum) == Enum.sort(inline_enum),
             "enum drift at $defs.#{standalone_def}.properties.#{prop} — sign_recipe_v1 has #{inspect(standalone_enum)}, exchange_v3 has #{inspect(inline_enum)}"
    end
  end

  defp to_ok_or_errors({:ok, _}), do: :ok
  defp to_ok_or_errors({:error, errors}), do: {:error, errors}
end

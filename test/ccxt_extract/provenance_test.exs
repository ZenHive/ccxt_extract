defmodule CcxtExtract.ProvenanceTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.Provenance

  describe "build_default/0" do
    test "returns a map whose values are only raw or derived (never override)" do
      provenance = Provenance.build_default()

      values = provenance |> Map.values() |> Enum.uniq() |> Enum.sort()
      assert values == ["derived", "raw"]
    end

    test "every key is a JSON Pointer string starting with '/'" do
      for {k, _v} <- Provenance.build_default() do
        assert is_binary(k)
        assert String.starts_with?(k, "/")
      end
    end

    test "includes known raw section pointers" do
      provenance = Provenance.build_default()

      assert provenance["/runtime/describe"] == "raw"
      assert provenance["/runtime/url_templates"] == "raw"
      assert provenance["/structure/class_info"] == "raw"
      assert provenance["/structure/sign_method"] == "raw"
    end

    test "tags known derived fields as derived" do
      provenance = Provenance.build_default()

      assert provenance["/runtime/symbols_index"] == "derived"
      assert provenance["/runtime/symbol_patterns"] == "derived"
      assert provenance["/structure/authenticated_sections"] == "derived"
      assert provenance["/structure/unified_endpoints"] == "derived"
      assert provenance["/exchange/tier"] == "derived"
    end

    test "pruned pointers are absent from the default map" do
      # Schema 3.0.0 (Task 117) dropped /runtime/markets, /structure/parse_methods,
      # and /structure/ws_methods from the emitted output. Provenance must not
      # declare them — the provenance_covers_schema invariant would flag them as
      # orphan declarations.
      provenance = Provenance.build_default()

      refute Map.has_key?(provenance, "/runtime/markets")
      refute Map.has_key?(provenance, "/structure/parse_methods")
      refute Map.has_key?(provenance, "/structure/ws_methods")
    end

    test "tags mixed handle_errors sub-keys individually" do
      provenance = Provenance.build_default()

      assert provenance["/structure/handle_errors/method"] == "raw"
      assert provenance["/structure/handle_errors/exceptions"] == "raw"
      assert provenance["/structure/handle_errors/http_exceptions"] == "raw"
      assert provenance["/structure/handle_errors/error_code_fields"] == "derived"
      assert provenance["/structure/handle_errors/throw_dispatches"] == "derived"
    end

    test "raw_pointers and derived_pointers are disjoint" do
      raw = MapSet.new(Provenance.raw_pointers())
      derived = MapSet.new(Provenance.derived_pointers())

      assert MapSet.disjoint?(raw, derived),
             "a pointer cannot be both raw and derived: #{inspect(MapSet.intersection(raw, derived))}"
    end
  end

  describe "stamp_overrides/2" do
    test "replaces an existing raw entry with override" do
      base = Provenance.build_default()
      stamped = Provenance.stamp_overrides(base, ["/structure/sign_method"])

      assert base["/structure/sign_method"] == "raw"
      assert stamped["/structure/sign_method"] == "override"
    end

    test "replaces an existing derived entry with override" do
      base = Provenance.build_default()
      stamped = Provenance.stamp_overrides(base, ["/structure/authenticated_sections"])

      assert base["/structure/authenticated_sections"] == "derived"
      assert stamped["/structure/authenticated_sections"] == "override"
    end

    test "adds new entries for sub-tree paths deeper than default granularity" do
      base = Provenance.build_default()

      stamped =
        Provenance.stamp_overrides(base, [
          "/structure/sign_method/params/timestamp",
          "/runtime/describe/urls/api/public"
        ])

      assert stamped["/structure/sign_method/params/timestamp"] == "override"
      assert stamped["/runtime/describe/urls/api/public"] == "override"
      # Original entries still there.
      assert stamped["/structure/sign_method"] == "raw"
      assert stamped["/runtime/describe"] == "raw"
    end

    test "is identity on an empty path list" do
      base = Provenance.build_default()
      assert Provenance.stamp_overrides(base, []) == base
    end

    test "last write wins when a path is listed twice" do
      stamped = Provenance.stamp_overrides(%{"/a" => "raw"}, ["/a", "/a"])

      assert stamped["/a"] == "override"
    end
  end

  describe "validate/1" do
    test "accepts the default map" do
      assert :ok == Provenance.validate(Provenance.build_default())
    end

    test "accepts the default map after override stamping" do
      stamped = Provenance.stamp_overrides(Provenance.build_default(), ["/structure/sign_method"])
      assert :ok == Provenance.validate(stamped)
    end

    test "rejects non-JSON-Pointer keys" do
      assert {:error, [reason]} = Provenance.validate(%{"no_slash" => "raw"})
      assert reason =~ "JSON Pointer"
    end

    test "rejects invalid tier values" do
      assert {:error, [reason]} = Provenance.validate(%{"/foo" => "maybe"})
      assert reason =~ "raw/derived/override"
    end

    test "rejects non-maps" do
      assert {:error, _} = Provenance.validate("not a map")
      assert {:error, _} = Provenance.validate(nil)
    end

    test "collects all errors rather than stopping at the first" do
      assert {:error, reasons} = Provenance.validate(%{"no_slash" => "bogus"})
      assert length(reasons) == 2
    end
  end
end

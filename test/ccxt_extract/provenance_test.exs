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

    test "includes known raw section pointers (v4 shape)" do
      provenance = Provenance.build_default()

      assert provenance["/raw/describe"] == "raw"
      assert provenance["/raw/url_templates"] == "raw"
      assert provenance["/raw/class_info"] == "raw"
      assert provenance["/auth/sign_method"] == "raw"
    end

    test "tags known derived fields as derived (v4 shape)" do
      provenance = Provenance.build_default()

      assert provenance["/markets/symbols_index"] == "derived"
      assert provenance["/markets/patterns"] == "derived"
      assert provenance["/auth/authenticated_sections"] == "derived"
      assert provenance["/endpoints/unified"] == "derived"
      assert provenance["/endpoints/descriptors"] == "derived"
      assert provenance["/exchange/tier"] == "derived"
    end

    test "section_pointers returns the complete declared pointer set" do
      assert "/endpoints/descriptors" in Provenance.section_pointers()
      assert Enum.sort(Provenance.section_pointers()) == Provenance.section_pointers()
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

    test "tags mixed handle_errors sub-keys individually (v4 shape)" do
      provenance = Provenance.build_default()

      assert provenance["/errors/handle_errors/method"] == "raw"
      assert provenance["/errors/handle_errors/exceptions"] == "raw"
      assert provenance["/errors/handle_errors/http_exceptions"] == "raw"
      assert provenance["/errors/handle_errors/error_code_fields"] == "derived"
      assert provenance["/errors/handle_errors/throw_dispatches"] == "derived"
    end

    test "raw_pointers and derived_pointers are disjoint" do
      raw = MapSet.new(Provenance.raw_pointers())
      derived = MapSet.new(Provenance.derived_pointers())

      assert MapSet.disjoint?(raw, derived),
             "a pointer cannot be both raw and derived: #{inspect(MapSet.intersection(raw, derived))}"
    end
  end

  describe "stamp_overrides/2" do
    test "replaces an existing raw entry with override (v4 shape)" do
      base = Provenance.build_default()
      stamped = Provenance.stamp_overrides(base, ["/auth/sign_method"])

      assert base["/auth/sign_method"] == "raw"
      assert stamped["/auth/sign_method"] == "override"
    end

    test "replaces an existing derived entry with override (v4 shape)" do
      base = Provenance.build_default()
      stamped = Provenance.stamp_overrides(base, ["/auth/authenticated_sections"])

      assert base["/auth/authenticated_sections"] == "derived"
      assert stamped["/auth/authenticated_sections"] == "override"
    end

    test "adds new entries for sub-tree paths deeper than default granularity" do
      base = Provenance.build_default()

      stamped =
        Provenance.stamp_overrides(base, [
          "/auth/sign_method/params/timestamp",
          "/raw/describe/urls/api/public"
        ])

      assert stamped["/auth/sign_method/params/timestamp"] == "override"
      assert stamped["/raw/describe/urls/api/public"] == "override"
      # Original entries still there.
      assert stamped["/auth/sign_method"] == "raw"
      assert stamped["/raw/describe"] == "raw"
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

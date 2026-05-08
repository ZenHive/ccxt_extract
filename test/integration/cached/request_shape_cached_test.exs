defmodule CcxtExtract.Integration.Cached.RequestShapeCachedTest do
  @moduledoc """
  Corpus-level assertions for Phase 11 / Tasks 70 + 71
  (`structure.request_shape`).

  Reads the committed `priv/output/*.json` files — does NOT re-run
  extraction. Pins concrete expected outcomes for priority exchanges
  so drift surfaces immediately in CI.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Paths
  alias CcxtExtract.RequestShape

  @moduletag :integration

  defp load_exchange!(id) do
    id
    |> then(&Path.join(["output", "#{&1}.json"]))
    |> Paths.priv()
    |> File.read!()
    |> Jason.decode!()
  end

  defp record(id, section) do
    exchange = load_exchange!(id)
    record_map = get_in(exchange, ["structure", "request_shape"]) || %{}
    Map.get(record_map, section, :missing)
  end

  defp request_shape_map(id) do
    exchange = load_exchange!(id)
    get_in(exchange, ["structure", "request_shape"]) || %{}
  end

  defp output_dir, do: Paths.priv("output")

  defp committed_exchange_ids do
    case File.ls(output_dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.reject(&(String.starts_with?(&1, "_") or &1 == "exchange_v3.json"))
        |> Enum.map(&String.replace_suffix(&1, ".json", ""))

      {:error, _} ->
        []
    end
  end

  describe "shape lock — every priority record conforms to RequestShapeRecord" do
    test "every section has the five required keys" do
      for id <- committed_exchange_ids() do
        recipe_map = request_shape_map(id)

        for {section, record} <- recipe_map do
          assert record |> Map.keys() |> Enum.sort() ==
                   Enum.sort(RequestShape.required_keys()),
                 "[#{id}.#{section}] required-keys mismatch: got #{inspect(Map.keys(record))}"

          assert is_integer(record["patch_count"]) and record["patch_count"] >= 0,
                 "[#{id}.#{section}] patch_count must be a non-negative integer"

          assert is_nil(record["unresolved_reason"]) or
                   record["unresolved_reason"] in RequestShape.unresolved_reasons(),
                 "[#{id}.#{section}] unresolved_reason out of vocabulary: #{inspect(record["unresolved_reason"])}"

          assert is_nil(record["body_encoding"]) or
                   record["body_encoding"] in RequestShape.body_encodings(),
                 "[#{id}.#{section}] body_encoding out of vocabulary: #{inspect(record["body_encoding"])}"
        end
      end
    end

    test "endpoints entries have http_verb, path_template, path_params" do
      verbs = ~w(GET POST PUT DELETE PATCH)

      for id <- committed_exchange_ids() do
        recipe_map = request_shape_map(id)

        for {section, record} <- recipe_map do
          case record["endpoints"] do
            nil ->
              :ok

            endpoints when is_list(endpoints) ->
              for endpoint <- endpoints do
                assert endpoint["http_verb"] in verbs,
                       "[#{id}.#{section}] verb #{inspect(endpoint["http_verb"])} out of vocabulary"

                assert is_binary(endpoint["path_template"]),
                       "[#{id}.#{section}] non-string path_template: #{inspect(endpoint["path_template"])}"

                assert is_list(endpoint["path_params"]),
                       "[#{id}.#{section}] non-list path_params: #{inspect(endpoint["path_params"])}"

                for param <- endpoint["path_params"] do
                  assert is_binary(param["name"]) and param["name"] != "",
                         "[#{id}.#{section}] path_params entry missing name: #{inspect(param)}"

                  assert param["source"] == "params",
                         "[#{id}.#{section}] path_params entry must have source=params: #{inspect(param)}"
                end
              end
          end
        end
      end
    end

    test "biconditional honesty holds across the corpus" do
      for id <- committed_exchange_ids() do
        recipe_map = request_shape_map(id)

        for {section, record} <- recipe_map do
          tag = record["unresolved_reason"]
          all_populated? = RequestShape.all_derivation_fields_populated?(record)

          if is_nil(tag) do
            assert all_populated?,
                   "[#{id}.#{section}] unresolved_reason is nil but a derivation field is null"
          else
            refute all_populated?,
                   "[#{id}.#{section}] unresolved_reason is #{inspect(tag)} but every derivation field is populated"
          end
        end
      end
    end
  end

  describe "priority-exchange populated cases (biconditional flips to nil)" do
    test "okx.private — fully resolved JSON body" do
      r = record("okx", "private")

      assert r["body_encoding"] == "json"
      assert r["content_type"] == "application/json"
      assert r["unresolved_reason"] == nil
      assert is_list(r["endpoints"])
      # okx.private has hundreds of endpoints in describe.api — credible
      # per-exchange floor, scope-independent (okx is tier 1, always present).
      assert length(r["endpoints"]) >= 200
    end

    test "gate.private — fully resolved JSON body (nested describe.api walk)" do
      # gate's describe.api.private is nested (spot/futures/...) — the
      # walker recurses to find every HTTP-method leaf.
      r = record("gate", "private")

      assert r["body_encoding"] == "json"
      assert r["content_type"] == "application/json"
      assert r["unresolved_reason"] == nil
      assert is_list(r["endpoints"])
      # gate.private is tier 2, always present; per-exchange floor.
      assert length(r["endpoints"]) >= 100
    end

    test "kucoin.private — fully resolved JSON body" do
      r = record("kucoin", "private")

      assert r["body_encoding"] == "json"
      assert r["content_type"] == "application/json"
      assert r["unresolved_reason"] == nil
      assert is_list(r["endpoints"])
    end

    test "hyperliquid.private — single POST endpoint, json body" do
      r = record("hyperliquid", "private")

      # describe.api.private has only post: { "exchange": 1 } — exactly
      # one endpoint.
      assert is_list(r["endpoints"])
      assert length(r["endpoints"]) == 1
      [endpoint] = r["endpoints"]
      assert endpoint["http_verb"] == "POST"
      assert endpoint["path_template"] == "exchange"
      assert endpoint["path_params"] == []

      # Body fields populate — sign() body is `body = this.json(...)`.
      assert r["body_encoding"] == "json"
      assert r["content_type"] == "application/json"
      assert r["unresolved_reason"] == nil
    end
  end

  describe "honest-empty / partial cases (biconditional keeps reason set)" do
    test "binance.private — ambiguous_body (RSA/HMAC fork) keeps endpoints, nulls body" do
      # binance's sign() picks RSA, EdDSA, or HMAC + json or urlencode
      # by secret format — multiple body encoders surface in the same
      # method, so body_encoding can't be honestly disambiguated.
      r = record("binance", "private")

      assert r["unresolved_reason"] == "ambiguous_body"
      # Honesty-Rule: endpoints stay populated even when body is ambiguous.
      assert is_list(r["endpoints"])
      assert r["endpoints"] != []
      assert r["body_encoding"] == nil
      assert r["content_type"] == nil
    end

    test "bybit.private — ambiguous_body (multiple encoders)" do
      r = record("bybit", "private")

      assert r["unresolved_reason"] == "ambiguous_body"
      assert is_list(r["endpoints"])
      assert r["body_encoding"] == nil
      assert r["content_type"] == nil
    end

    test "kraken.private — ambiguous_body (json + urlencodeNested)" do
      r = record("kraken", "private")

      assert r["unresolved_reason"] == "ambiguous_body"
      assert is_list(r["endpoints"])
      assert r["body_encoding"] == nil
    end
  end

  describe "key-set parity with authenticated_sections" do
    test "every authenticated_sections entry has a request_shape record" do
      for id <- committed_exchange_ids() do
        exchange = load_exchange!(id)
        sections = get_in(exchange, ["structure", "authenticated_sections"]) || []
        recipe_map = get_in(exchange, ["structure", "request_shape"]) || %{}

        recipe_keys = recipe_map |> Map.keys() |> MapSet.new()
        section_keys = MapSet.new(sections)

        assert MapSet.equal?(recipe_keys, section_keys),
               "[#{id}] request_shape keys #{inspect(MapSet.to_list(recipe_keys))} != authenticated_sections #{inspect(MapSet.to_list(section_keys))}"
      end
    end

    test "binance has a record per authenticated_sections entry (multi-section exchange)" do
      exchange = load_exchange!("binance")
      sections = get_in(exchange, ["structure", "authenticated_sections"]) || []
      recipe_map = get_in(exchange, ["structure", "request_shape"]) || %{}

      assert length(sections) >= 10, "binance is the canonical multi-section exchange"
      assert recipe_map |> Map.keys() |> Enum.sort() == Enum.sort(sections)
    end
  end

  describe "schema-version + provenance integration" do
    test "schema_version on every output is the request_shape-introduced version" do
      ids = committed_exchange_ids()
      assert ids != [], "expected priv/output to be populated"

      for id <- ids do
        exchange = load_exchange!(id)

        assert exchange["schema_version"] == CcxtExtract.Schema.schema_version(),
               "[#{id}] schema_version mismatch — pipeline output drift?"
      end
    end

    test "_provenance tags /structure/request_shape as derived" do
      for id <- committed_exchange_ids() do
        exchange = load_exchange!(id)
        provenance = exchange["_provenance"] || %{}

        # Either tagged "derived" by Provenance.build_default/0, or
        # "override" if a curated override re-stamped it. Anything
        # else is drift.
        tag = Map.get(provenance, "/structure/request_shape")
        assert tag in ["derived", "override"], "[#{id}] /structure/request_shape provenance tag = #{inspect(tag)}"
      end
    end
  end
end

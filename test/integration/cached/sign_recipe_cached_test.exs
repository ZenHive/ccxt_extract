defmodule CcxtExtract.Integration.Cached.SignRecipeCachedTest do
  @moduledoc """
  Corpus-level assertions for Task 65 (crypto_op + signature_placement).

  Reads the committed `priv/output/*.json` files — does NOT re-run
  extraction. Pins concrete expected outcomes for priority exchanges so
  drift surfaces immediately in CI.
  """
  use ExUnit.Case, async: true

  import CcxtExtract.Test.ScopeThresholds

  alias CcxtExtract.Paths

  @moduletag :integration

  defp load_exchange!(id) do
    id
    |> then(&Path.join(["output", "#{&1}.json"]))
    |> Paths.priv()
    |> File.read!()
    |> Jason.decode!()
  end

  defp recipe(id, section) do
    exchange = load_exchange!(id)
    recipe_map = get_in(exchange, ["auth", "sign_recipe"]) || %{}
    Map.get(recipe_map, section, :missing)
  end

  describe "priority-exchange crypto_op + placement" do
    test "okx.private — HMAC-SHA256 header OK-ACCESS-SIGN (fully resolved after Task 68)" do
      record = recipe("okx", "private")

      assert record["crypto_op"] == %{"algo" => "hmac_sha256"}
      assert record["signature_placement"] == %{"location" => "header", "key" => "OK-ACCESS-SIGN"}
      # Task 68 closed the last derivation field; Task 69's biconditional
      # then auto-flipped unresolved_reason to nil — okx is the first
      # (and today, the only) priority recipe to fully resolve.
      assert record["unresolved_reason"] == nil
    end

    test "kucoin.private — HMAC-SHA256 header KC-API-SIGN (via ternary)" do
      # kucoin's sign() does `headers = condition ? existing : { 'KC-API-SIGN': signature }`.
      # Derive walks both branches of the ternary to find the match.
      record = recipe("kucoin", "private")

      assert record["crypto_op"] == %{"algo" => "hmac_sha256"}
      assert record["signature_placement"] == %{"location" => "header", "key" => "KC-API-SIGN"}
      assert record["unresolved_reason"] == "not_yet_derived"
    end

    test "kraken.private — HMAC-SHA512 header API-Sign" do
      record = recipe("kraken", "private")

      assert record["crypto_op"] == %{"algo" => "hmac_sha512"}
      assert record["signature_placement"] == %{"location" => "header", "key" => "API-Sign"}
    end

    test "bitget.private — HMAC-SHA256 header ACCESS-SIGN" do
      case skip_unless_corpus_in_scope!("bitget") do
        :skip ->
          :ok

        :proceed ->
          record = recipe("bitget", "private")

          assert record["crypto_op"] == %{"algo" => "hmac_sha256"}

          assert record["signature_placement"] == %{
                   "location" => "header",
                   "key" => "ACCESS-SIGN"
                 }
      end
    end

    test "gate.private — HMAC-SHA512 header SIGN" do
      record = recipe("gate", "private")

      assert record["crypto_op"] == %{"algo" => "hmac_sha512"}
      assert record["signature_placement"] == %{"location" => "header", "key" => "SIGN"}
    end

    test "binance.private — ambiguous_ast (RSA/EdDSA/HMAC conditional)" do
      # binance's sign() picks RSA, EdDSA, or HMAC based on secret format.
      # Honesty Rule: emit null crypto_op + ambiguous_ast, because no
      # single algo is correct for every call. Future work can carry a
      # disambiguation if a priority consumer needs it.
      record = recipe("binance", "private")

      assert record["crypto_op"] == nil
      assert record["unresolved_reason"] == "ambiguous_ast"
    end

    test "bybit.private — ambiguous_ast (RSA/HMAC conditional by key format)" do
      record = recipe("bybit", "private")

      assert record["crypto_op"] == nil
      assert record["unresolved_reason"] == "ambiguous_ast"
    end

    test "hyperliquid.private — custom signing family (no crypto op in sign())" do
      record = recipe("hyperliquid", "private")

      assert record["crypto_op"] == nil
      assert record["signature_placement"] == nil
      assert record["unresolved_reason"] == "custom_signing_family"
    end
  end

  describe "canonical_string per-verb map (Tasks 66a + 66b)" do
    test "okx.private emits hmac_simple GET + hmac_with_body POST" do
      record = recipe("okx", "private")
      cs = record["canonical_string"]

      assert is_map(cs), "okx.private.canonical_string should be a per-verb map, got: #{inspect(cs)}"

      # Task 66a: GET branch — hmac_simple with query.
      assert %{"GET" => %{"family" => "hmac_simple", "components" => get_components, "encoding" => "url_encoded"}} = cs
      assert Enum.map(get_components, & &1["source"]) == ["timestamp", "method", "path", "literal", "query"]
      assert Enum.find(get_components, &(&1["source"] == "literal"))["value"] == "?"

      # Task 66b: POST branch — hmac_with_body with body.
      assert %{"POST" => %{"family" => "hmac_with_body", "components" => post_components, "encoding" => "url_encoded"}} =
               cs

      assert Enum.map(post_components, & &1["source"]) == ["timestamp", "method", "path", "body"]
    end

    test "Binance sections remain null under ambiguous_ast" do
      # 12 binance sections all short-circuit to nil at the recipe level
      # (RSA/EdDSA/HMAC conditional on key format). Task 66a explicitly
      # respects this tag — see CanonicalString.@terminal_reasons.
      for section <-
            ~w(private sapi sapiV2 sapiV3 sapiV4 papi papiV2 fapiPrivate fapiPrivateV2 fapiPrivateV3 dapiPrivate dapiPrivateV2 eapiPrivate) do
        record = recipe("binance", section)

        assert record["canonical_string"] == nil,
               "binance.#{section} expected null canonical_string (ambiguous_ast), got: #{inspect(record["canonical_string"])}"
      end
    end

    test "Bybit and Hyperliquid also null" do
      # Bybit: ambiguous_ast (RSA/HMAC by key format)
      # Hyperliquid: custom_signing_family (signing lives outside sign())
      assert recipe("bybit", "private")["canonical_string"] == nil
      assert recipe("hyperliquid", "private")["canonical_string"] == nil
    end

    test "Kraken/Gate remain null — pre-hash body pattern is Task 66e scope" do
      # Kraken: binaryConcat(encode(url), hash(encode(nonce + body)))
      # Gate: payloadArray.join("\n") with SHA512(body) slot
      # Neither decomposes cleanly under the current component vocabulary.
      assert recipe("kraken", "private")["canonical_string"] == nil
      assert recipe("gate", "private")["canonical_string"] == nil
    end

    test "KuCoin/Coinbaseexchange remain null — reassigned identifier in chain" do
      # Both use `let payload = ''; if (method === 'POST') { payload = this.json(...) }`
      # style. The reassignment-filter rejects these because the initial value
      # doesn't represent the value at hmac-time. Revisit when Task 66a gets
      # per-verb-reassignment-in-chain analysis.
      assert recipe("coinbaseexchange", "private")["canonical_string"] == nil

      for section <- ~w(private broker earn futuresPrivate) do
        assert recipe("kucoin", section)["canonical_string"] == nil,
               "kucoin.#{section} expected null"
      end
    end

    test "Deribit remains null — requires source: \"nonce\" (Task 66e)" do
      # Deribit canonical: timestamp + "\n" + nonce + "\n" + method + "\n" + path + "\n\n"
      # The nonce component doesn't have a clean source tag; tagging as
      # timestamp would produce a consumer-ambiguous recipe (two timestamps).
      assert recipe("deribit", "private")["canonical_string"] == nil
    end
  end

  describe "auth_headers + nonce (Task 67)" do
    test "okx.private — three canonical headers, iso8601 timestamp_ms nonce" do
      record = recipe("okx", "private")

      assert record["auth_headers"] == [
               %{"name" => "OK-ACCESS-KEY", "source" => "api_key"},
               %{"name" => "OK-ACCESS-PASSPHRASE", "source" => "passphrase"},
               %{"name" => "OK-ACCESS-TIMESTAMP", "source" => "timestamp"}
             ]

      assert record["nonce"] == %{"source" => "timestamp_ms", "format" => "iso8601"}
    end

    test "coinbaseexchange.private — key/timestamp/passphrase triad" do
      record = recipe("coinbaseexchange", "private")

      assert record["auth_headers"] == [
               %{"name" => "CB-ACCESS-KEY", "source" => "api_key"},
               %{"name" => "CB-ACCESS-TIMESTAMP", "source" => "timestamp"},
               %{"name" => "CB-ACCESS-PASSPHRASE", "source" => "passphrase"}
             ]

      assert record["nonce"] == %{"source" => "timestamp_ms", "format" => "string"}
    end

    test "gate.private — terminal-binding chain resolves to timestamp_sec / string" do
      # Gate's sign() chain:
      #   const nonce = this.nonce();
      #   const timestamp = this.parseToInt(nonce / 1000);
      #   const timestampString = timestamp.toString();
      #   headers = { 'KEY': this.apiKey, 'Timestamp': timestampString, ... };
      # The terminal-binding filter picks `timestampString` (the wire
      # value); identifier-chain resolution walks it through the two
      # intermediate bindings down to this.nonce().
      record = recipe("gate", "private")

      assert record["auth_headers"] == [
               %{"name" => "KEY", "source" => "api_key"},
               %{"name" => "Timestamp", "source" => "timestamp"}
             ]

      assert record["nonce"] == %{"source" => "timestamp_sec", "format" => "string"}
    end

    test "kraken.private — single API-Key header; nonce rides in body" do
      record = recipe("kraken", "private")

      assert record["auth_headers"] == [%{"name" => "API-Key", "source" => "api_key"}]
      assert record["nonce"] == %{"source" => "timestamp_ms", "format" => "string"}
    end

    test "bitfinex.private — bfx-apikey + bfx-nonce (timestamp)" do
      record = recipe("bitfinex", "private")

      # Order reflects walker emission order (depth-first over the sign()
      # body); consumers look up by name so this isn't contractual.
      assert Enum.sort_by(record["auth_headers"], & &1["name"]) == [
               %{"name" => "bfx-apikey", "source" => "api_key"},
               %{"name" => "bfx-nonce", "source" => "timestamp"}
             ]

      assert record["nonce"] == %{"source" => "timestamp_ms", "format" => "string"}
    end

    test "deribit.private — empty list (signature IS the Authorization header)" do
      record = recipe("deribit", "private")

      # The only header assigned in sign() is Authorization, whose value
      # is a compound string containing the HMAC signature. Signature-
      # referencing headers are excluded → list ends up empty.
      assert record["auth_headers"] == []
      assert record["nonce"] == %{"source" => "timestamp_ms", "format" => "string"}
    end

    test "htx.private — empty list (all auth material in query string)" do
      record = recipe("htx", "private")

      assert record["auth_headers"] == []
      assert record["nonce"] == %{"source" => "timestamp_ms", "format" => "iso8601"}
    end

    test "hyperliquid.private — null (terminal custom_signing_family)" do
      record = recipe("hyperliquid", "private")

      assert record["auth_headers"] == nil
      assert record["nonce"] == nil
    end

    test "binance.private — null under ambiguous_ast (RSA/EdDSA/HMAC)" do
      record = recipe("binance", "private")

      assert record["auth_headers"] == nil
      assert record["nonce"] == nil
    end

    test "bybit.private — null under ambiguous_ast (RSA/HMAC)" do
      record = recipe("bybit", "private")

      assert record["auth_headers"] == nil
      assert record["nonce"] == nil
    end

    # TODO(Task 151): kucoin.private has a `this.extend({...}, headers)`
    # header init shape + a conditional `if (this.options['partner'])`
    # block with unclassified HMAC-passphrase + partner-signature
    # references. The `this.extend(ObjectExpression, _)` shape isn't yet
    # supported by AuthHeaders (the classifier looks for
    # `headers = ObjectExpression` directly), so the list aborts to
    # null. Nonce populates cleanly because kucoin's
    # `const timestamp = this.nonce().toString()` binding is
    # unambiguous. Revisit when a priority consumer needs kucoin
    # auth_headers populated — likely via an override, not classifier
    # extension.
    test "kucoin.private — auth_headers null (this.extend shape unsupported) but nonce populated" do
      record = recipe("kucoin", "private")

      assert record["auth_headers"] == nil
      assert record["nonce"] == %{"source" => "timestamp_ms", "format" => "string"}
    end
  end

  describe "pre_sign_transforms (Task 68)" do
    test "okx.private — base64 digest + json_encode body (1-hop alias trace)" do
      # okx's sign() shape:
      #   body = this.json(query); auth += body;
      #   signature = this.hmac(this.encode(auth), …, 'base64');
      # The crypto call references `auth`, not `body`. The 1-hop tracer in
      # PreSignTransforms.body_reached_by_crypto?/2 follows auth's `+=`
      # reassignment back to body, surfacing json_encode/body.
      record = recipe("okx", "private")

      assert record["pre_sign_transforms"] == [
               %{"op" => "base64_encode", "target" => "signature"},
               %{"op" => "json_encode", "target" => "body"}
             ]
    end

    test "kucoin.private — base64 digest (shared across all four private sections)" do
      # kucoin uses identical sign() for private/broker/earn/futuresPrivate.
      for section <- ~w(private broker earn futuresPrivate) do
        record = recipe("kucoin", section)

        assert record["pre_sign_transforms"] == [%{"op" => "base64_encode", "target" => "signature"}],
               "kucoin.#{section} unexpected pre_sign_transforms"
      end
    end

    test "deribit.private — default-hex digest (no 4th arg on this.hmac)" do
      record = recipe("deribit", "private")

      assert record["pre_sign_transforms"] == [
               %{"op" => "hex_encode", "target" => "signature"}
             ]
    end

    test "bitfinex.private — default-hex digest + json_encode body (1-hop alias trace)" do
      # bitfinex shape mirrors okx but with a `const auth = … + body` concat
      # inside the declarator (instead of `auth += body`):
      #   body = this.json(query);
      #   const auth = '/api/' + request + nonce + body;
      #   signature = this.hmac(this.encode(auth), this.encode(secret), sha384);
      # 1-hop tracer follows auth's declarator RHS to body.
      record = recipe("bitfinex", "private")

      assert record["pre_sign_transforms"] == [
               %{"op" => "hex_encode", "target" => "signature"},
               %{"op" => "json_encode", "target" => "body"}
             ]
    end

    test "gate.private — default-hex digest under SHA-512" do
      record = recipe("gate", "private")

      assert record["pre_sign_transforms"] == [
               %{"op" => "hex_encode", "target" => "signature"}
             ]
    end

    test "kraken.private — base64 digest on the outer hmac (SHA-512)" do
      # Kraken's signing is a 4-step chain (binary hash → binaryConcat →
      # base64-decode secret → hmac sha512 base64). Only the outer
      # hmac's digest lands in pre_sign_transforms — the intermediate
      # binary concat belongs to canonical_string construction (and
      # stays null there until Task 66e lands the binary chain).
      record = recipe("kraken", "private")

      assert record["pre_sign_transforms"] == [
               %{"op" => "base64_encode", "target" => "signature"}
             ]
    end

    test "coinbaseexchange.private — base64 digest on signature" do
      record = recipe("coinbaseexchange", "private")

      assert record["pre_sign_transforms"] == [
               %{"op" => "base64_encode", "target" => "signature"}
             ]
    end

    test "htx.private — two-stage: base64 digest + url_encode wrapping" do
      # htx places the base64 signature into the URL query via
      # this.urlencode({ Signature: signature }). The detector catches
      # both the hmac digest AND the post-hmac url_encode wrap.
      record = recipe("htx", "private")

      assert record["pre_sign_transforms"] == [
               %{"op" => "base64_encode", "target" => "signature"},
               %{"op" => "url_encode", "target" => "signature"}
             ]
    end

    test "hyperliquid.private — null (terminal custom_signing_family)" do
      record = recipe("hyperliquid", "private")

      assert record["pre_sign_transforms"] == nil
    end

    test "binance.private — null under ambiguous_ast (RSA/EdDSA/HMAC)" do
      record = recipe("binance", "private")

      assert record["pre_sign_transforms"] == nil
    end

    test "bybit.private — null under ambiguous_ast (RSA/HMAC)" do
      record = recipe("bybit", "private")

      assert record["pre_sign_transforms"] == nil
    end
  end

  describe "shape invariants across all exchanges" do
    test "every recipe record has the required nine keys" do
      required =
        Enum.sort(
          ~w(crypto_op canonical_string signature_placement auth_headers nonce timestamp pre_sign_transforms unresolved_reason patch_count)
        )

      Enum.each(all_exchange_files(), fn file ->
        data = file |> File.read!() |> Jason.decode!()
        recipe_map = get_in(data, ["auth", "sign_recipe"]) || %{}

        for {section, record} <- recipe_map do
          keys = record |> Map.keys() |> Enum.sort()

          assert keys == required,
                 "exchange #{inspect(data["exchange"]["id"])} section #{inspect(section)} has keys #{inspect(keys)}"
        end
      end)
    end

    test "populated crypto_op values are in the closed vocabulary" do
      valid_algos = ~w(hmac_sha256 hmac_sha512 hmac_sha384 ed25519 rsa custom)

      Enum.each(all_exchange_files(), fn file ->
        data = file |> File.read!() |> Jason.decode!()
        recipe_map = get_in(data, ["auth", "sign_recipe"]) || %{}

        for {section, record} <- recipe_map do
          case record["crypto_op"] do
            nil ->
              :ok

            %{"algo" => algo} ->
              assert algo in valid_algos,
                     "exchange #{inspect(data["exchange"]["id"])} section #{inspect(section)} has unknown algo #{inspect(algo)}"
          end
        end
      end)
    end

    test "populated signature_placement values use closed-vocabulary location" do
      valid_locations = ~w(header query body)

      Enum.each(all_exchange_files(), fn file ->
        data = file |> File.read!() |> Jason.decode!()
        recipe_map = get_in(data, ["auth", "sign_recipe"]) || %{}

        for {section, record} <- recipe_map do
          case record["signature_placement"] do
            nil ->
              :ok

            %{"location" => loc, "key" => key} when is_binary(key) ->
              assert loc in valid_locations,
                     "exchange #{inspect(data["exchange"]["id"])} section #{inspect(section)} has unknown location #{inspect(loc)}"

              assert String.length(key) > 0
          end
        end
      end)
    end
  end

  describe "tier-scoped coverage" do
    test "at least some tier1 exchanges get a populated crypto_op" do
      # The point of Task 65: priority exchanges with straightforward
      # HMAC signing should no longer emit null crypto_op. This is a
      # corpus-level smoke test — if this fires, the derivation broke
      # for the whole universe.
      populated =
        Enum.flat_map(all_exchange_files(), fn file ->
          data = file |> File.read!() |> Jason.decode!()
          recipe_map = get_in(data, ["auth", "sign_recipe"]) || %{}

          Enum.filter(recipe_map, fn {_section, record} ->
            is_map(record["crypto_op"])
          end)
        end)

      assert populated != [],
             "expected at least one exchange×section with a populated crypto_op after Task 65"
    end
  end

  defp all_exchange_files do
    "output"
    |> Paths.priv()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.reject(fn path ->
      name = Path.basename(path)
      String.starts_with?(name, "_")
    end)
  end
end

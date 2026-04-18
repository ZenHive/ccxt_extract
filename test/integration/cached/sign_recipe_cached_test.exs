defmodule CcxtExtract.Integration.Cached.SignRecipeCachedTest do
  @moduledoc """
  Corpus-level assertions for Task 65 (crypto_op + signature_placement).

  Reads the committed `priv/output/*.json` files — does NOT re-run
  extraction. Pins concrete expected outcomes for priority exchanges so
  drift surfaces immediately in CI.
  """
  use ExUnit.Case, async: true

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
    recipe_map = get_in(exchange, ["structure", "sign_recipe"]) || %{}
    Map.get(recipe_map, section, :missing)
  end

  describe "priority-exchange crypto_op + placement" do
    test "okx.private — HMAC-SHA256 header OK-ACCESS-SIGN" do
      record = recipe("okx", "private")

      assert record["crypto_op"] == %{"algo" => "hmac_sha256"}
      assert record["signature_placement"] == %{"location" => "header", "key" => "OK-ACCESS-SIGN"}
      assert record["unresolved_reason"] == "not_yet_derived"
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
      record = recipe("bitget", "private")

      assert record["crypto_op"] == %{"algo" => "hmac_sha256"}
      assert record["signature_placement"] == %{"location" => "header", "key" => "ACCESS-SIGN"}
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

  describe "shape invariants across all exchanges" do
    test "every recipe record has the required eight keys" do
      required =
        Enum.sort(
          ~w(crypto_op canonical_string signature_placement auth_headers nonce pre_sign_transforms unresolved_reason patch_count)
        )

      Enum.each(all_exchange_files(), fn file ->
        data = file |> File.read!() |> Jason.decode!()
        recipe_map = get_in(data, ["structure", "sign_recipe"]) || %{}

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
        recipe_map = get_in(data, ["structure", "sign_recipe"]) || %{}

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
        recipe_map = get_in(data, ["structure", "sign_recipe"]) || %{}

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
          recipe_map = get_in(data, ["structure", "sign_recipe"]) || %{}

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

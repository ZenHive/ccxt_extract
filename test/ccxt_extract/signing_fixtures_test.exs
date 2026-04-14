defmodule CcxtExtract.SigningFixturesTest do
  @moduledoc """
  Corpus-level regression invariants over `priv/fixtures/signing/*.json`.

  These tests read the committed fixtures from disk; they do not regenerate
  them. Regeneration happens via `mix ccxt_extract.signing_fixtures` and is
  too slow (QuickBEAM, 107 exchanges) for the unit suite. The committed
  fixtures are the observable contract ccxt_client (and other consumers)
  depends on; these tests guard against silent regressions in the probe.
  """
  use ExUnit.Case, async: true

  @fixtures_dir Path.join([File.cwd!(), "priv", "fixtures", "signing"])

  defp load!(id) do
    @fixtures_dir
    |> Path.join("#{id}.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp case_named(fixture, name) do
    Enum.find(fixture["cases"], &(&1["name"] == name))
  end

  defp describe_api(id) do
    path = Path.join([File.cwd!(), "priv", "discoveries", "describe", "#{id}.json"])

    case File.read(path) do
      {:ok, body} -> body |> Jason.decode!() |> get_in(["describe", "api"])
      _ -> nil
    end
  end

  describe "Gemini probe (ccxt_client T66 consumer contract)" do
    test "private_post_order emits X-GEMINI-PAYLOAD + X-GEMINI-SIGNATURE" do
      fixture = load!("gemini")
      c = case_named(fixture, "private_post_order")

      assert c, "gemini.json missing private_post_order case"
      headers = c["output"]["headers"]
      assert is_map(headers), "gemini private_post_order has no headers"
      assert is_binary(headers["X-GEMINI-PAYLOAD"]) and headers["X-GEMINI-PAYLOAD"] != ""
      assert is_binary(headers["X-GEMINI-SIGNATURE"]) and headers["X-GEMINI-SIGNATURE"] != ""
      assert is_binary(headers["X-GEMINI-APIKEY"]) and headers["X-GEMINI-APIKEY"] != ""
    end

    test "apiKey placeholder contains 'account' so Gemini's master-key guard accepts it" do
      fixture = load!("gemini")
      assert String.contains?(fixture["credentials"]["apiKey"], "account")
    end
  end

  describe "matcher — two-pass regex recovers CamelCase and concatenated lowercase" do
    @tag :matcher
    test "bitflyer (concatenated lowercase: getticker, getbalance, sendchildorder) emits 3 cases" do
      fixture = load!("bitflyer")
      assert length(fixture["cases"]) == 3
      assert case_named(fixture, "public_get_ticker")
      assert case_named(fixture, "private_get_balance")
      assert case_named(fixture, "private_post_order")
    end

    @tag :matcher
    test "ndax (CamelCase: GetTickerHistory, GetUserAccountInfos, SendOrder) emits all applicable cases" do
      fixture = load!("ndax")
      assert case_named(fixture, "public_get_ticker")
      assert case_named(fixture, "private_get_balance")
      assert case_named(fixture, "private_post_order")
    end

    @tag :matcher
    test "independentreserve (CamelCase: GetMarketSummary, PlaceLimitOrder) emits public + order" do
      fixture = load!("independentreserve")

      assert case_named(fixture, "public_get_ticker"),
             "independentreserve should match GetMarketSummary via CamelCase boundary"

      assert case_named(fixture, "private_post_order"),
             "independentreserve should match PlaceLimitOrder via CamelCase boundary"
    end
  end

  describe "credential retry — Orderly-family base58 + derive hex" do
    test "derive private_post_order succeeds with non-zero hex privateKey" do
      fixture = load!("derive")

      assert case_named(fixture, "private_post_order"),
             "derive private_post_order should succeed with hex privateKey ending in 01"
    end

    test "woofipro private_post_order succeeds via base58 retry" do
      fixture = load!("woofipro")

      assert case_named(fixture, "private_post_order"),
             "woofipro private_post_order should succeed after base58-format retry"
    end

    test "modetrade private_post_order succeeds via base58 retry" do
      fixture = load!("modetrade")

      assert case_named(fixture, "private_post_order"),
             "modetrade private_post_order should succeed after base58-format retry"
    end
  end

  describe "false-positive guards" do
    test "no fixture uses change_subaccount_name as a balance or order case path" do
      @fixtures_dir
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.reject(&String.starts_with?(Path.basename(&1), "_"))
      |> Enum.each(fn path ->
        fixture = path |> File.read!() |> Jason.decode!()

        for c <- fixture["cases"],
            c["name"] in ["private_get_balance", "private_post_order"] do
          assert c["input"]["path"] != "change_subaccount_name",
                 "#{fixture["exchange"]} falsely matched change_subaccount_name for #{c["name"]}"
        end
      end)
    end
  end

  describe "manifest sanity" do
    test "_manifest.json count matches per-exchange file count" do
      manifest =
        @fixtures_dir
        |> Path.join("_manifest.json")
        |> File.read!()
        |> Jason.decode!()

      on_disk =
        @fixtures_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.reject(&String.starts_with?(&1, "_"))
        |> length()

      assert manifest["count"] == on_disk
      assert manifest["count"] == length(manifest["exchanges"])
    end
  end

  describe "coverage — matcher regression guard" do
    test "public_get_ticker succeeds whenever describe().api has a matching public GET path" do
      fixtures = Path.wildcard(Path.join(@fixtures_dir, "*.json"))

      offenders =
        fixtures
        |> Enum.reject(&String.starts_with?(Path.basename(&1), "_"))
        |> Enum.flat_map(fn path ->
          fixture = path |> File.read!() |> Jason.decode!()
          id = fixture["exchange"]
          picked? = Enum.any?(fixture["cases"], &(&1["name"] == "public_get_ticker"))

          cond do
            picked? -> []
            has_matching_path?(describe_api(id), "public", "get") -> [id]
            true -> []
          end
        end)

      assert offenders == [],
             "exchanges skip public_get_ticker despite having a matching public GET path: #{inspect(offenders)}"
    end
  end

  @ticker_tokens ~w(tick ticker tickers symbol symbols market markets instrument instruments)

  defp has_matching_path?(nil, _vis, _m), do: false

  defp has_matching_path?(api, visibility, method) when is_map(api) do
    api
    |> public_get_paths(visibility, method)
    |> Enum.any?(&path_has_ticker_token?/1)
  end

  defp public_get_paths(node, visibility, method) when is_map(node) do
    Enum.flat_map(node, fn
      {k, v} when is_map(v) ->
        sk = String.downcase(to_string(k))

        if String.contains?(sk, visibility) do
          extract_method(v, method)
        else
          public_get_paths(v, visibility, method)
        end

      _ ->
        []
    end)
  end

  defp public_get_paths(_, _, _), do: []

  defp extract_method(node, method) when is_map(node) do
    Enum.flat_map(node, fn {k, v} -> extract_entry(k, v, method) end)
  end

  defp extract_method(_, _), do: []

  defp extract_entry(k, v, method) do
    if String.downcase(to_string(k)) == method do
      paths_of(v)
    else
      if is_map(v), do: extract_method(v, method), else: []
    end
  end

  defp paths_of(v) when is_list(v), do: Enum.map(v, &to_path_string/1)
  defp paths_of(v) when is_map(v), do: Map.keys(v)
  defp paths_of(_), do: []

  defp path_has_ticker_token?(path) when is_binary(path) do
    path
    |> String.split(~r/[_\-\/.]+/)
    |> Enum.flat_map(&split_camel/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.any?(&(&1 in @ticker_tokens))
  end

  defp split_camel(""), do: []
  defp split_camel(seg), do: Regex.split(~r/(?<=[a-z])(?=[A-Z])|(?=[A-Z][a-z])/, seg, trim: true)

  defp to_path_string(s) when is_binary(s), do: s
  defp to_path_string(%{"path" => p}) when is_binary(p), do: p
  defp to_path_string(other), do: to_string(other)
end

defmodule CcxtExtract.ExchangesIntegrationTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.Exchanges

  @moduletag :integration
  @moduletag timeout: 60_000

  # Reference exchange sets from CLAUDE.md
  @all_reference ~w(binance bybit okx deribit coinbaseexchange kraken kucoin gate htx bitmex hyperliquid aster lighter)
  @known_aliases [{"huobi", "htx"}, {"gateio", "gate"}]
  @known_variants ~w(binanceus binancecoinm binanceusdm okxus kucoinfutures)

  # Run extraction once for the module — QuickBEAM boot is ~13s
  setup_all do
    {:ok, exchanges} = Exchanges.extract()
    %{exchanges: exchanges}
  end

  describe "extract/0" do
    test "extracts 100+ exchanges with correct field types", %{exchanges: exchanges} do
      assert length(exchanges) >= 100,
             "Expected 100+ exchanges, got #{length(exchanges)}"

      for ex <- exchanges do
        assert is_binary(ex["id"]), "id should be a string, got: #{inspect(ex["id"])}"
        assert is_binary(ex["name"]), "name should be a string for #{ex["id"]}"
        assert is_boolean(ex["certified"]), "certified should be boolean for #{ex["id"]}"
        assert is_boolean(ex["pro"]), "pro should be boolean for #{ex["id"]}"
        assert is_boolean(ex["alias"]), "alias should be boolean for #{ex["id"]}"
        assert is_list(ex["country"]), "country should be a list for #{ex["id"]}"

        assert is_nil(ex["version"]) or is_binary(ex["version"]),
               "version should be nil or string for #{ex["id"]}"

        case ex["referral"] do
          nil ->
            :ok

          %{"url" => url, "discount" => discount} ->
            assert is_binary(url), "referral url should be string for #{ex["id"]}"
            assert is_number(discount), "referral discount should be number for #{ex["id"]}"

          other ->
            flunk("Unexpected referral format for #{ex["id"]}: #{inspect(other)}")
        end
      end
    end

    test "exchanges are sorted by id", %{exchanges: exchanges} do
      ids = Enum.map(exchanges, & &1["id"])
      assert ids == Enum.sort(ids)
    end

    test "binance is certified, pro, and not an alias", %{exchanges: exchanges} do
      binance = Enum.find(exchanges, &(&1["id"] == "binance"))

      assert binance, "binance should be in the exchange list"
      assert binance["certified"] == true
      assert binance["pro"] == true
      assert binance["alias"] == false
    end

    test "known aliases are marked", %{exchanges: exchanges} do
      # huobi is a known alias for htx
      aliases = Enum.filter(exchanges, & &1["alias"])
      alias_ids = Enum.map(aliases, & &1["id"])

      assert aliases != [], "Expected at least 1 alias exchange"

      assert "huobi" in alias_ids or "huobijp" in alias_ids,
             "Expected huobi or huobijp to be marked as alias, got: #{inspect(alias_ids)}"
    end
  end

  describe "reference exchanges exist and are not aliases" do
    for id <- @all_reference do
      test "#{id} exists and is not an alias", %{exchanges: exchanges} do
        ex = find_exchange(exchanges, unquote(id))
        assert ex, "#{unquote(id)} should exist in exchange list"
        assert ex["alias"] == false, "#{unquote(id)} should not be an alias"
      end
    end
  end

  describe "known aliases are correctly marked" do
    for {alias_id, _parent} <- @known_aliases do
      test "#{alias_id} is marked as alias", %{exchanges: exchanges} do
        ex = find_exchange(exchanges, unquote(alias_id))
        assert ex, "#{unquote(alias_id)} should exist in exchange list"
        assert ex["alias"] == true, "#{unquote(alias_id)} should be marked as alias"
      end
    end
  end

  describe "variants are not aliases" do
    for id <- @known_variants do
      test "#{id} exists and is not an alias", %{exchanges: exchanges} do
        ex = find_exchange(exchanges, unquote(id))
        assert ex, "#{unquote(id)} should exist in exchange list"
        assert ex["alias"] == false, "#{unquote(id)} is a variant, not an alias"
      end
    end
  end

  describe "write!/1" do
    @tag :tmp_dir
    test "writes valid JSON with metadata envelope", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "exchanges.json")

      exchanges = [
        %{
          "id" => "test_exchange",
          "name" => "Test",
          "certified" => false,
          "pro" => false,
          "version" => "v1",
          "country" => ["US"],
          "alias" => false,
          "referral" => nil
        }
      ]

      assert :ok = Exchanges.write!(exchanges, output_path)
      assert File.exists?(output_path)

      output = output_path |> File.read!() |> Jason.decode!()
      assert is_binary(output["extracted_at"])
      assert output["count"] == 1
      assert length(output["exchanges"]) == 1
      assert hd(output["exchanges"])["id"] == "test_exchange"
    end
  end

  defp find_exchange(exchanges, id), do: Enum.find(exchanges, &(&1["id"] == id))
end

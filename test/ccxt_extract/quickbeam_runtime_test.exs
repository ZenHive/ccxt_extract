defmodule CcxtExtract.QuickbeamRuntimeTest do
  # async: false — boots a real QuickBEAM runtime with the CCXT bundle
  use ExUnit.Case, async: false

  alias CcxtExtract.QuickbeamRuntime

  @moduletag :integration
  @moduletag :extraction
  @moduletag timeout: 60_000

  setup_all do
    {:ok, rt} = QuickbeamRuntime.start()
    on_exit(fn -> QuickbeamRuntime.stop(rt) end)
    :ok = QuickbeamRuntime.install_extraction_helpers(rt)
    %{rt: rt}
  end

  describe "install_extraction_helpers/1" do
    test "defines getNonAliasIds as a sorted JSON array of non-alias class keys", %{rt: rt} do
      {:ok, json} = QuickBEAM.call(rt, "getNonAliasIds", [])
      ids = Jason.decode!(json)

      assert is_list(ids)
      assert length(ids) >= 90, "expected 90+ non-alias exchange ids, got #{length(ids)}"
      assert ids == Enum.sort(ids), "ids should be sorted"
      assert "binance" in ids
      refute "Exchange" in ids
      refute "Precise" in ids
    end

    test "populates _errorNameMap with real CCXT error class names", %{rt: rt} do
      {:ok, map} = QuickBEAM.get_global(rt, "_errorNameMap")

      assert is_map(map)
      assert map_size(map) > 0, "_errorNameMap should have entries"
      assert "ExchangeError" in Map.values(map)
    end

    test "_prepare converts undefined and functions to sentinel strings", %{rt: rt} do
      js = """
        globalThis._ccxtTestPrepareResult = JSON.stringify(_prepare({
          u: undefined,
          n: null,
          s: "hi",
          nums: [1, 2, undefined],
          fn: function anonFn() {}
        }));
      """

      {:ok, _} = QuickBEAM.eval(rt, js)
      {:ok, json} = QuickBEAM.get_global(rt, "_ccxtTestPrepareResult")
      decoded = Jason.decode!(json)

      assert decoded["u"] == "__undefined"
      assert decoded["n"] == nil
      assert decoded["s"] == "hi"
      assert decoded["nums"] == [1, 2, "__undefined"]
      assert String.starts_with?(decoded["fn"], "__function:")
    end
  end
end

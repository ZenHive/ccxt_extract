defmodule CcxtExtract.QuickbeamRuntime do
  @moduledoc """
  Shared QuickBEAM runtime bootstrap for CCXT extraction.

  Starts a QuickBEAM runtime with browser globals configured and the CCXT
  browser bundle loaded. Reusable by all extraction modules that need the
  CCXT runtime (exchanges, describe keys, markets, etc.).

  ## Usage

      {:ok, rt} = CcxtExtract.QuickbeamRuntime.start()
      {:ok, result} = QuickBEAM.call(rt, "someFunction", [args])
      CcxtExtract.QuickbeamRuntime.stop(rt)
  """

  @doc """
  Start a QuickBEAM runtime with CCXT loaded.

  Sets browser globals (`self`, `window`, `navigator`, `location`) and loads
  the CCXT browser bundle. Returns `{:ok, runtime}` on success.

  Raises if the CCXT browser bundle is not installed (run `mix ccxt_extract.setup` first).
  """
  @spec start() :: {:ok, pid()}
  def start do
    Application.ensure_all_started(:quickbeam)

    {:ok, rt} = QuickBEAM.start()

    # self/window must BE globalThis — set_global with atoms converts to strings
    QuickBEAM.eval(rt, "globalThis.self = globalThis; globalThis.window = globalThis")
    QuickBEAM.set_global(rt, "navigator", %{"userAgent" => "QuickBEAM"})
    QuickBEAM.set_global(rt, "location", %{"protocol" => "https:"})

    # Load the pre-built CCXT browser bundle into the JS runtime.
    # This is the documented pattern — the bundle is a vendor artifact, not user input.
    bundle = File.read!(CcxtExtract.Paths.bundle())
    {:ok, _} = QuickBEAM.call(rt, "eval", [bundle])

    {:ok, rt}
  end

  @doc """
  Stop a QuickBEAM runtime and free resources.
  """
  @spec stop(pid()) :: :ok
  def stop(rt) do
    QuickBEAM.stop(rt)
  end
end

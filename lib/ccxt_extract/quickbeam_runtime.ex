defmodule CcxtExtract.QuickbeamRuntime do
  @moduledoc """
  Shared QuickBEAM runtime bootstrap for CCXT extraction.

  Starts a QuickBEAM runtime with browser globals configured and the CCXT
  browser bundle loaded. Reusable by all extraction modules that need the
  CCXT runtime (exchanges, describe keys, markets, etc.).

  Also hosts the shared JS helper installer `install_extraction_helpers/1`,
  which defines three globals used by every describe-style extractor:

    * `getNonAliasIds()` — sorted JSON array of non-alias class keys
    * `_errorNameMap` — minified `Function.name` → real error class name
    * `_prepare(val)` — tree walker that converts `undefined` / functions to
      JSON-safe sentinels (`"__undefined"`, `"__function:<name>"`)

  ## Usage

      {:ok, rt} = CcxtExtract.QuickbeamRuntime.start()
      :ok = CcxtExtract.QuickbeamRuntime.install_extraction_helpers(rt)
      {:ok, result} = QuickBEAM.call(rt, "someFunction", [args])
      CcxtExtract.QuickbeamRuntime.stop(rt)
  """

  # Build map: minified Function.name → real error class name.
  # CCXT error classes set `this.name = 'ExchangeError'` in their constructors,
  # which survives minification (string literals are never mangled).
  @js_error_name_map """
  globalThis._errorNameMap = {};
  for (const k of Object.keys(ccxt)) {
    const v = ccxt[k];
    if (typeof v === 'function') {
      try {
        const inst = new v();
        if (inst instanceof Error && inst.name) {
          _errorNameMap[v.name] = inst.name;
        }
      } catch(e) {}
    }
  }
  """

  # "Non-alias" means `new ccxt[k]().describe().alias` is falsy. Excludes the
  # base `Exchange` and utility `Precise` classes (constructing them throws or
  # has no `.id`, so the try/catch filter drops them).
  @js_get_non_alias_ids """
  globalThis.getNonAliasIds = function() {
    const ids = Object.keys(ccxt).filter(k => {
      try {
        return typeof ccxt[k] === 'function' &&
               k !== 'Exchange' && k !== 'Precise' &&
               new ccxt[k]().id;
      } catch(e) { return false; }
    });
    return JSON.stringify(ids.filter(id => {
      const d = new ccxt[id]().describe();
      return !d.alias;
    }).sort());
  }
  """

  # Tree walker that converts JS-only values into JSON-safe sentinels before
  # JSON.stringify (which silently drops `undefined` and functions):
  #   undefined → "__undefined"
  #   function  → "__function:<ErrorClassName>" via _errorNameMap lookup
  # Reads globalThis._errorNameMap defensively so install order doesn't matter.
  @js_prepare """
  globalThis._prepare = function(val) {
    if (val === undefined) return '__undefined';
    if (val === null) return null;
    if (typeof val === 'function') {
      const map = globalThis._errorNameMap || {};
      const resolved = map[val.name] || val.name || 'anonymous';
      return '__function:' + resolved;
    }
    if (Array.isArray(val)) return val.map(_prepare);
    if (typeof val === 'object') {
      const out = {};
      for (const k of Object.keys(val)) {
        out[k] = _prepare(val[k]);
      }
      return out;
    }
    return val;
  }
  """

  @doc """
  Start a QuickBEAM runtime with CCXT loaded.

  Sets browser globals (`self`, `window`, `navigator`, `location`) and loads
  the CCXT browser bundle. Returns `{:ok, runtime}` on success.

  ## Options

    * `:memory_limit` - maximum JS heap size in bytes (default: QuickBEAM default, 256MB)

  Raises if the CCXT browser bundle is not installed (run `mix ccxt_extract.setup` first).
  """
  @spec start(keyword()) :: {:ok, pid()}
  def start(opts \\ []) do
    Application.ensure_all_started(:quickbeam)

    quickbeam_opts =
      case Keyword.get(opts, :memory_limit) do
        nil -> []
        limit -> [memory_limit: limit]
      end

    {:ok, rt} = QuickBEAM.start(quickbeam_opts)

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

  @doc """
  Install the three shared extraction helpers into a running runtime:
  `getNonAliasIds()`, `_errorNameMap`, and `_prepare()`.

  Callers install once after `start/1` and before evaluating their own
  caller-specific `@js_setup`. Each helper is small (< 1 KB) and installs
  in sub-ms.
  """
  @spec install_extraction_helpers(pid()) :: :ok
  def install_extraction_helpers(rt) do
    Enum.each([@js_error_name_map, @js_get_non_alias_ids, @js_prepare], fn js ->
      {:ok, _} = QuickBEAM.eval(rt, js)
    end)
  end
end

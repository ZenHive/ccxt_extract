# Load full CCXT JS runtime via QuickBEAM and extract describe() for all exchanges
#
# Note: QuickBEAM.eval is used intentionally here to run CCXT's JavaScript runtime
# on the BEAM. This is the core use case — executing CCXT JS code in-process.
#
# Usage: mix run examples/3_quickbeam_describe.exs [exchange]
# Default: all exchanges

target = List.first(System.argv())

bundle_path = "node_modules/ccxt/dist/ccxt.browser.min.js"

if !File.exists?(bundle_path) do
  IO.puts("CCXT browser bundle not found. Run: mix npm.install ccxt")
  System.halt(1)
end

bundle = File.read!(bundle_path)
IO.puts("Loading CCXT (#{div(byte_size(bundle), 1024)}KB)...")

{:ok, rt} = QuickBEAM.start()

# Stub browser globals that CCXT's browser build expects
# self and window must reference globalThis (not just be defined) so that
# browser bundles that assign to self.X or window.X attach to the global scope.
QuickBEAM.eval(rt, "globalThis.self = globalThis; globalThis.window = globalThis")
QuickBEAM.set_global(rt, "navigator", %{"userAgent" => "QuickBEAM"})
QuickBEAM.set_global(rt, "location", %{"protocol" => "https:"})

{load_ms, {:ok, _}} = :timer.tc(fn -> QuickBEAM.call(rt, "eval", [bundle]) end)
IO.puts("Loaded in #{div(load_ms, 1000)}ms\n")

case target do
  nil ->
    # All exchanges — use QuickBEAM.call to invoke a JS function
    {:ok, _} =
      QuickBEAM.call(rt, "eval", [
        """
        globalThis.getAllDescribe = function() {
          const ids = Object.keys(ccxt).filter(k => {
            try { return typeof ccxt[k] === 'function' && k !== 'Exchange' && k !== 'Precise' && new ccxt[k]().id; }
            catch(e) { return false; }
          });
          return JSON.stringify(ids.map(id => {
            const d = new ccxt[id]().describe();
            return {
              id: d.id, name: d.name, certified: !!d.certified, pro: !!d.pro,
              has: Object.keys(d.has || {}).length,
              exceptions: Object.keys((d.exceptions || {}).exact || {}).length,
              features: Object.keys(d.features || {}),
              api_sections: Object.keys(d.api || {}).length
            };
          }));
        }
        """
      ])

    {:ok, json} = QuickBEAM.call(rt, "getAllDescribe", [])
    exchanges = Jason.decode!(json)
    IO.puts("#{length(exchanges)} exchanges:\n")

    IO.puts(
      String.pad_trailing("ID", 25) <>
        String.pad_trailing("Name", 25) <>
        String.pad_trailing("Has", 6) <>
        String.pad_trailing("Exc", 6) <>
        String.pad_trailing("API", 6) <>
        String.pad_trailing("Cert", 6) <>
        "Pro"
    )

    IO.puts(String.duplicate("-", 80))

    for ex <- exchanges do
      IO.puts(
        String.pad_trailing(ex["id"], 25) <>
          String.pad_trailing(ex["name"] || "", 25) <>
          String.pad_trailing("#{ex["has"]}", 6) <>
          String.pad_trailing("#{ex["exceptions"]}", 6) <>
          String.pad_trailing("#{ex["api_sections"]}", 6) <>
          String.pad_trailing(if(ex["certified"], do: "Y", else: ""), 6) <>
          if(ex["pro"], do: "Y", else: "")
      )
    end

  exchange ->
    # Single exchange — full describe() dump
    {:ok, _} =
      QuickBEAM.call(rt, "eval", [
        """
        globalThis.getDescribe = function(id) {
          const d = new ccxt[id]().describe();
          return JSON.stringify(d, (key, val) => {
            if (typeof val === 'function') return val.name || 'Function';
            return val;
          }, 2);
        }
        """
      ])

    {:ok, json} = QuickBEAM.call(rt, "getDescribe", [exchange])
    IO.puts(json)
end

QuickBEAM.stop(rt)

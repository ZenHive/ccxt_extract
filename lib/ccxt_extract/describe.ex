defmodule CcxtExtract.Describe do
  @moduledoc """
  Extract the complete `describe()` output for all CCXT exchanges via QuickBEAM.

  Each exchange's `describe()` contains the full configuration: `has`, `api`,
  `exceptions`, `fees`, `timeframes`, `options`, `commonCurrencies`,
  `requiredCredentials`, and more. This module extracts every key and every
  nested value — nothing is filtered.

  Output is one JSON file per exchange in `priv/discoveries/describe/`, plus a
  manifest at `priv/discoveries/describe/_manifest.json`.

  ## Usage

      {:ok, results} = CcxtExtract.Describe.extract()
      CcxtExtract.Describe.write!(results)
  """

  require Logger

  @output_dir "discoveries/describe"

  # TODO: Exchange ID enumeration pattern duplicated from exchanges.ex and describe_keys.ex —
  # now 3 modules use the same getNonAliasIds logic. Extract shared JS helper.
  #
  # JS functions for full describe() extraction.
  #
  # getNonAliasIds: returns sorted list of exchange IDs that are not aliases.
  # getFullDescribe: returns one exchange's complete describe() as JSON.
  #
  # The prepare() function handles two edge cases before JSON serialization:
  # - Functions (error classes, parseNumber, etc.) -> "__function:<name>"
  # - undefined values (which JSON.stringify would silently drop) -> "__undefined"
  #
  # Security note: This JS code runs inside QuickBEAM (sandboxed Zig NIF runtime)
  # against the CCXT vendor bundle — no user input is involved.
  @js_setup """
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

  globalThis.getFullDescribe = function(id) {
    const ex = new ccxt[id]();
    const d = ex.describe();

    // Walk the object tree, converting undefined to sentinel and functions to names.
    // We must do this before JSON.stringify because stringify silently drops undefined.
    function prepare(val) {
      if (val === undefined) return '__undefined';
      if (val === null) return null;
      if (typeof val === 'function') return '__function:' + (val.name || 'anonymous');
      if (Array.isArray(val)) return val.map(prepare);
      if (typeof val === 'object') {
        const out = {};
        for (const k of Object.keys(val)) {
          out[k] = prepare(val[k]);
        }
        return out;
      }
      return val;
    }

    return JSON.stringify(prepare(d));
  }
  """

  @doc """
  Extract the complete describe() for all non-alias exchanges.

  Starts a QuickBEAM runtime, enumerates non-alias exchange IDs, then extracts
  each exchange's full describe() one at a time. Returns a sorted list of
  `%{"id" => id, "describe" => describe_map}` maps.
  """
  @spec extract() :: {:ok, [map()]}
  def extract do
    {:ok, rt} = CcxtExtract.QuickbeamRuntime.start()

    try do
      {:ok, _} = QuickBEAM.eval(rt, @js_setup)
      {:ok, ids_json} = QuickBEAM.call(rt, "getNonAliasIds", [])
      ids = Jason.decode!(ids_json)

      Logger.info("Extracting describe() for #{length(ids)} exchanges...")

      results =
        ids
        |> Enum.with_index(1)
        |> Enum.map(fn {id, idx} ->
          if rem(idx, 20) == 0, do: Logger.info("  #{idx}/#{length(ids)}...")
          extract_one(rt, id)
        end)

      {:ok, results}
    after
      CcxtExtract.QuickbeamRuntime.stop(rt)
    end
  end

  @doc """
  Extract a single exchange's complete describe() from an active runtime.
  """
  @spec extract_one(pid(), String.t()) :: map()
  def extract_one(rt, id) do
    {:ok, json} = QuickBEAM.call(rt, "getFullDescribe", [id])

    %{
      "id" => id,
      "describe" => Jason.decode!(json)
    }
  end

  @doc """
  Write per-exchange JSON files and a manifest.

  Creates `priv/discoveries/describe/<exchange_id>.json` for each exchange
  and `priv/discoveries/describe/_manifest.json` with the full exchange list.
  """
  @spec write!([map()], String.t()) :: :ok
  def write!(results, output_dir \\ CcxtExtract.Paths.priv(@output_dir)) do
    File.mkdir_p!(output_dir)

    # Remove stale .json files from previous runs so the directory only contains
    # files from the current extraction. Without this, renamed/removed exchanges
    # would leave orphan files that disagree with _manifest.json.
    output_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.each(&File.rm!/1)

    extracted_at = DateTime.to_iso8601(DateTime.utc_now())

    # Write per-exchange files
    for result <- results do
      path = Path.join(output_dir, "#{result["id"]}.json")

      output = %{
        "id" => result["id"],
        "extracted_at" => extracted_at,
        "describe" => result["describe"]
      }

      File.write!(path, Jason.encode!(output, pretty: true))
    end

    # Write manifest
    ids = Enum.map(results, & &1["id"])
    manifest_path = Path.join(output_dir, "_manifest.json")

    manifest = %{
      "extracted_at" => extracted_at,
      "count" => length(results),
      "exchanges" => ids
    }

    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
    :ok
  end
end

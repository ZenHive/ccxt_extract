defmodule CcxtExtract.Exchanges do
  @moduledoc """
  Extract exchange metadata from CCXT via QuickBEAM runtime.

  Loads the full CCXT browser bundle, enumerates all exchange classes,
  and extracts per-exchange metadata from `describe()`: id, name, certified,
  pro, version, country, alias status, and referral URLs.

  ## Usage

      {:ok, exchanges} = CcxtExtract.Exchanges.extract()
      CcxtExtract.Exchanges.write!(exchanges)
  """

  @output_file "exchanges.json"

  # JS function that enumerates CCXT exchange classes and extracts describe() fields.
  # Uses eval() to register a global function — this is the standard QuickBEAM pattern
  # for defining callable JS functions (not a security concern, no user input involved).
  @js_extract_exchanges """
  globalThis.extractExchanges = function() {
    const ids = Object.keys(ccxt).filter(k => {
      try {
        return typeof ccxt[k] === 'function' &&
               k !== 'Exchange' && k !== 'Precise' &&
               new ccxt[k]().id;
      } catch(e) { return false; }
    });

    return JSON.stringify(ids.map(id => {
      const d = new ccxt[id]().describe();
      return {
        id: d.id,
        name: d.name,
        certified: !!d.certified,
        pro: !!d.pro,
        version: d.version || null,
        country: d.countries || [],
        alias: !!d.alias,
        referral: (d.urls || {}).referral || null
      };
    }));
  }
  """

  @doc """
  Extract exchange metadata from CCXT runtime.

  Starts a QuickBEAM runtime, loads CCXT, enumerates all exchanges,
  and returns normalized metadata for each.

  Raises if CCXT is not installed (run `mix ccxt_extract.setup` first).
  """
  @spec extract() :: {:ok, [map()]}
  def extract do
    {:ok, rt} = CcxtExtract.QuickbeamRuntime.start()

    try do
      {:ok, _} = QuickBEAM.eval(rt, @js_extract_exchanges)
      {:ok, json} = QuickBEAM.call(rt, "extractExchanges", [])

      exchanges =
        json
        |> Jason.decode!()
        |> Enum.map(&normalize_exchange/1)
        |> Enum.sort_by(& &1["id"])

      {:ok, exchanges}
    after
      CcxtExtract.QuickbeamRuntime.stop(rt)
    end
  end

  @doc """
  Write extracted exchanges to `priv/discoveries/exchanges.json`.

  Creates the output directory if needed. Wraps the exchange list in a
  metadata envelope with timestamp and count.
  """
  @spec write!([map()], String.t()) :: :ok
  def write!(exchanges, output_path \\ CcxtExtract.Paths.out(Path.join("discoveries", @output_file))) do
    File.mkdir_p!(Path.dirname(output_path))

    output = %{
      "extracted_at" => CcxtExtract.Clock.timestamp(:extracted_at),
      "count" => length(exchanges),
      "exchanges" => exchanges
    }

    CcxtExtract.JsonIO.write_json!(output_path, output, pretty: true)
    :ok
  end

  @doc """
  Normalize a referral URL to consistent `{url, discount}` format.

  CCXT describe() returns referral in three variants:
  - `nil` — no referral program
  - `"https://..."` — plain URL string (discount unknown, defaults to 0)
  - `%{"url" => "..."}` — object without discount (e.g. hibachi)
  - `%{"url" => "...", "discount" => 0.1}` — object with discount

  Returns `nil` or `%{"url" => url, "discount" => discount}`.
  """
  @spec normalize_referral(nil | String.t() | map()) :: nil | map()
  def normalize_referral(nil), do: nil

  def normalize_referral(url) when is_binary(url) do
    %{"url" => url, "discount" => 0}
  end

  def normalize_referral(%{"url" => _} = referral) do
    Map.put_new(referral, "discount", 0)
  end

  def normalize_referral(_other), do: nil

  # Normalize a single exchange map — applies referral normalization
  defp normalize_exchange(exchange) do
    Map.update!(exchange, "referral", &normalize_referral/1)
  end
end

defmodule CcxtExtract.MarketValidation do
  @moduledoc """
  Validate extracted loadMarkets() data for structural correctness
  and spot-check against live exchange responses.

  Two validation layers:

  - **Layer 1 (structural)**: Offline validation of cached JSON files.
    Checks field presence, types, internal consistency, undefined density.
  - **Layer 2 (spot-check)**: Re-extract for a sample of exchanges via
    `LoadMarkets.extract/1`, compare market counts and symbol sets.

  Findings have severity levels:

  - **error**: Extraction bug — missing required field, wrong type
  - **warning**: Data quirk — type↔flag mismatch, known CCXT inconsistency

  Both layers report, never reject.

  ## Usage

      # Layer 1 only (offline)
      {:ok, report} = CcxtExtract.MarketValidation.validate()
      CcxtExtract.MarketValidation.write!(report)

      # Layer 1 + Layer 2 (live API)
      {:ok, report} = CcxtExtract.MarketValidation.validate(spot_check: true)
      {:ok, report} = CcxtExtract.MarketValidation.validate(
        spot_check: true,
        exchanges: ["binance", "bybit", "okx"]
      )
  """

  require Logger

  @output_file "discoveries/market_validation.json"
  @load_markets_dir "discoveries/load_markets"
  @default_spot_check_exchanges ["binance", "bybit", "okx"]

  # Fields that must be non-nil, non-__undefined strings on every market
  @required_fields ["symbol", "id", "base", "quote", "type"]

  # Fields that must be actual booleans (true/false) when present and not __undefined
  @boolean_fields ["spot", "swap", "future", "option", "contract", "linear", "inverse"]

  # Fields that must be maps when present and not __undefined
  @map_fields ["precision", "limits"]

  # Type values and their corresponding boolean flag
  @type_flag_map %{
    "spot" => "spot",
    "swap" => "swap",
    "future" => "future",
    "option" => "option"
  }

  # --- Layer 1: Structural Validation ---

  @doc """
  Validate all cached loadMarkets() data.

  Reads the manifest and per-exchange files from `priv/discoveries/load_markets/`.
  Optionally runs a spot-check against live API responses.

  ## Options

    * `:spot_check` - run Layer 2 spot-check (default: false)
    * `:exchanges` - exchanges for spot-check (default: binance, bybit, okx)
    * `:input_dir` - override input directory (for testing)
  """
  @spec validate(keyword()) :: {:ok, map()} | {:error, {:missing_input, String.t()}}
  def validate(opts \\ []) do
    input_dir = Keyword.get(opts, :input_dir, CcxtExtract.Paths.priv(@load_markets_dir))
    manifest_path = Path.join(input_dir, "_manifest.json")

    if File.exists?(manifest_path) do
      manifest = manifest_path |> File.read!() |> Jason.decode!()

      exchange_reports =
        Map.new(manifest["succeeded"], fn id ->
          path = Path.join(input_dir, "#{id}.json")
          data = path |> File.read!() |> Jason.decode!()
          {id, validate_exchange(data)}
        end)

      report = build_report(exchange_reports, manifest, opts)
      {:ok, report}
    else
      {:error, {:missing_input, manifest_path}}
    end
  end

  @doc """
  Validate a single exchange's market data. Pure function.

  Takes a decoded per-exchange JSON map (as written by `LoadMarkets.write!/2`)
  and returns a validation report with errors, warnings, and undefined density.
  """
  @spec validate_exchange(map()) :: map()
  def validate_exchange(exchange_data) do
    id = exchange_data["id"]
    markets = exchange_data["markets"] || %{}

    market_count_errors = check_market_count(exchange_data, markets)

    {errors, warnings, density} =
      Enum.reduce(markets, {[], [], {0, 0}}, fn {symbol, market}, {errs, warns, {undef, total}} ->
        market_errs = check_required_fields(market, symbol) ++ check_types(market, symbol)
        market_warns = check_consistency(market, symbol)
        {u, t} = count_undefined(market)

        {errs ++ market_errs, warns ++ market_warns, {undef + u, total + t}}
      end)

    density_pct =
      if elem(density, 1) > 0,
        do: Float.round(elem(density, 0) / elem(density, 1) * 100, 1),
        else: 0.0

    %{
      "id" => id,
      "market_count" => map_size(markets),
      "errors" => market_count_errors ++ errors,
      "warnings" => warnings,
      "undefined_density" => %{
        "undefined_count" => elem(density, 0),
        "total_fields" => elem(density, 1),
        "density_pct" => density_pct
      }
    }
  end

  @doc """
  Write validation report to JSON file.
  """
  @spec write!(map(), String.t()) :: :ok
  def write!(report, output_path \\ CcxtExtract.Paths.priv(@output_file)) do
    output_path
    |> Path.dirname()
    |> File.mkdir_p!()

    json = Jason.encode!(report, pretty: true)
    File.write!(output_path, json)
    :ok
  end

  # --- Layer 2: Spot-Check ---

  @doc """
  Spot-check cached data against fresh loadMarkets() extraction.

  Re-extracts for the given exchanges and compares market counts and symbol sets.
  Returns a list of comparison results.
  """
  @spec spot_check(map(), [String.t()]) :: {:ok, map()}
  def spot_check(cached_by_id, exchange_ids) do
    Logger.info("Spot-checking #{length(exchange_ids)} exchanges...")

    {:ok, fresh_results} =
      CcxtExtract.LoadMarkets.extract(exchanges: exchange_ids, delay_ms: 300)

    comparisons =
      Enum.map(fresh_results["succeeded"], fn fresh ->
        cached = Map.get(cached_by_id, fresh["id"])
        compare_exchange(fresh["id"], cached, fresh)
      end)

    failed_ids = Enum.map(fresh_results["failed"], & &1["id"])

    {:ok,
     %{
       "checked_at" => DateTime.to_iso8601(DateTime.utc_now()),
       "exchanges_checked" => exchange_ids,
       "exchanges_failed" => failed_ids,
       "results" => comparisons
     }}
  end

  # --- Private: Validation Checks ---

  # Cross-checks cached market_count against actual map size.
  # Returns errors if they disagree — indicates a corrupted cache file.
  defp check_market_count(exchange_data, markets) do
    cached_count = exchange_data["market_count"]
    actual_count = map_size(markets)

    cond do
      is_nil(cached_count) ->
        []

      cached_count != actual_count ->
        ["market_count mismatch: cached=#{cached_count}, actual=#{actual_count}"]

      true ->
        []
    end
  end

  # Checks that required fields are present and are non-nil, non-__undefined strings.
  defp check_required_fields(market, symbol) do
    Enum.flat_map(@required_fields, fn field ->
      value = Map.get(market, field)

      cond do
        is_nil(value) ->
          ["#{symbol}: missing required field '#{field}'"]

        value == "__undefined" ->
          ["#{symbol}: required field '#{field}' is __undefined"]

        not is_binary(value) ->
          ["#{symbol}: required field '#{field}' should be string, got #{inspect_type(value)}"]

        true ->
          []
      end
    end)
  end

  # Checks that boolean fields are booleans and map fields are maps.
  # __undefined boolean fields produce no error (CCXT sometimes omits them).
  defp check_types(market, symbol) do
    boolean_errors =
      Enum.flat_map(@boolean_fields, fn field ->
        value = Map.get(market, field)

        cond do
          is_nil(value) or value == "__undefined" -> []
          is_boolean(value) -> []
          true -> ["#{symbol}: '#{field}' should be boolean, got #{inspect_type(value)}"]
        end
      end)

    map_errors =
      Enum.flat_map(@map_fields, fn field ->
        value = Map.get(market, field)

        cond do
          is_nil(value) or value == "__undefined" -> []
          is_map(value) -> []
          true -> ["#{symbol}: '#{field}' should be map, got #{inspect_type(value)}"]
        end
      end)

    boolean_errors ++ map_errors
  end

  # Checks internal consistency between type field and boolean flags.
  # All inconsistencies are warnings, not errors — CCXT has known quirks.
  defp check_consistency(market, symbol) do
    check_type_flag(market, symbol) ++
      check_contract_type(market, symbol) ++
      check_derivative_flag(market, symbol, "linear") ++
      check_derivative_flag(market, symbol, "inverse")
  end

  # Checks if the type field's corresponding boolean flag is false.
  defp check_type_flag(market, symbol) do
    type = Map.get(market, "type")

    with flag_field when is_binary(flag_field) <- Map.get(@type_flag_map, type),
         flag_val when flag_val == false <- Map.get(market, flag_field) do
      ["#{symbol}: type='#{type}' but #{flag_field}=false"]
    else
      _ -> []
    end
  end

  # Checks contract=true is not paired with type=spot.
  defp check_contract_type(market, symbol) do
    case {Map.get(market, "contract"), Map.get(market, "type")} do
      {true, "spot"} -> ["#{symbol}: contract=true but type='spot'"]
      _ -> []
    end
  end

  # Checks that a derivative flag (linear/inverse) implies contract=true.
  defp check_derivative_flag(market, symbol, flag) do
    case {Map.get(market, flag), Map.get(market, "contract")} do
      {true, false} -> ["#{symbol}: #{flag}=true but contract=false"]
      _ -> []
    end
  end

  # Counts __undefined values in a market's top-level fields.
  # Returns {undefined_count, total_field_count}.
  defp count_undefined(market) do
    Enum.reduce(market, {0, 0}, fn {_key, value}, {undef, total} ->
      case value do
        "__undefined" -> {undef + 1, total + 1}
        _ -> {undef, total + 1}
      end
    end)
  end

  # --- Private: Report Building ---

  defp build_report(exchange_reports, _manifest, opts) do
    total_errors = exchange_reports |> Map.values() |> Enum.map(&length(&1["errors"])) |> Enum.sum()
    total_warnings = exchange_reports |> Map.values() |> Enum.map(&length(&1["warnings"])) |> Enum.sum()
    total_markets = exchange_reports |> Map.values() |> Enum.map(& &1["market_count"]) |> Enum.sum()

    exchanges_with_issues =
      Enum.count(exchange_reports, fn {_id, r} -> r["errors"] != [] or r["warnings"] != [] end)

    avg_density =
      case map_size(exchange_reports) do
        0 ->
          0.0

        n ->
          exchange_reports
          |> Map.values()
          |> Enum.map(& &1["undefined_density"]["density_pct"])
          |> Enum.sum()
          |> Kernel./(n)
          |> Float.round(1)
      end

    spot_check_result =
      if Keyword.get(opts, :spot_check, false) do
        input_dir = Keyword.get(opts, :input_dir, CcxtExtract.Paths.priv(@load_markets_dir))
        exchange_ids = Keyword.get(opts, :exchanges, @default_spot_check_exchanges)
        cached_by_id = load_cached_exchange_data(exchange_ids, input_dir)

        {:ok, result} = spot_check(cached_by_id, exchange_ids)
        result
      end

    %{
      "validated_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "exchange_count" => map_size(exchange_reports),
      "summary" => %{
        "exchanges_valid" => map_size(exchange_reports) - exchanges_with_issues,
        "exchanges_with_issues" => exchanges_with_issues,
        "total_markets_checked" => total_markets,
        "errors" => total_errors,
        "warnings" => total_warnings,
        "avg_undefined_density_pct" => avg_density
      },
      "exchanges" => exchange_reports,
      "spot_check" => spot_check_result
    }
  end

  # --- Private: Spot-Check Comparison ---

  defp compare_exchange(id, nil, fresh) do
    %{
      "id" => id,
      "market_count_cached" => nil,
      "market_count_fresh" => fresh["market_count"],
      "symbols_added" => [],
      "symbols_removed" => [],
      "symbols_added_count" => fresh["market_count"],
      "symbols_removed_count" => 0,
      "drift_summary" => "no cached data — #{fresh["market_count"]} markets in fresh extraction"
    }
  end

  defp compare_exchange(id, cached, fresh) do
    cached_symbols = cached["markets"] |> Map.keys() |> MapSet.new()
    fresh_symbols = fresh["markets"] |> Map.keys() |> MapSet.new()

    added = MapSet.difference(fresh_symbols, cached_symbols)
    removed = MapSet.difference(cached_symbols, fresh_symbols)

    %{
      "id" => id,
      "market_count_cached" => cached["market_count"],
      "market_count_fresh" => fresh["market_count"],
      "symbols_added" => MapSet.to_list(added),
      "symbols_removed" => MapSet.to_list(removed),
      "symbols_added_count" => MapSet.size(added),
      "symbols_removed_count" => MapSet.size(removed),
      "drift_summary" => "#{MapSet.size(added)} added, #{MapSet.size(removed)} removed"
    }
  end

  # Loads per-exchange JSON files into a map keyed by exchange id.
  defp load_cached_exchange_data(exchange_ids, input_dir) do
    Map.new(exchange_ids, fn id ->
      path = Path.join(input_dir, "#{id}.json")
      data = if File.exists?(path), do: path |> File.read!() |> Jason.decode!()
      {id, data}
    end)
  end

  defp inspect_type(value) when is_binary(value), do: "string"
  defp inspect_type(value) when is_integer(value), do: "integer"
  defp inspect_type(value) when is_float(value), do: "float"
  defp inspect_type(value) when is_boolean(value), do: "boolean"
  defp inspect_type(value) when is_list(value), do: "list"
  defp inspect_type(value) when is_map(value), do: "map"
  defp inspect_type(nil), do: "nil"
  defp inspect_type(_), do: "unknown"
end

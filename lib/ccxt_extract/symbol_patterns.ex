defmodule CcxtExtract.SymbolPatterns do
  @moduledoc """
  Derive symbol formatting patterns from extracted market data.

  Analyzes `runtime.markets` to produce per-market-type rules that consumers
  can use for symbol conversion (unified ↔ exchange-native). Patterns include
  separator style, case convention, ID structure, suffixes, and anomalies.

  This is a pure derivation module — no IO, no API calls. Called inline during
  pipeline assembly with already-loaded market and describe data.

  ## Output Structure

  Returns a map keyed by market type (`"spot"`, `"swap"`, `"future"`, `"option"`)
  with pattern analysis per type, plus `"currency_aliases"` from describe's
  `commonCurrencies`. Returns `nil` when no market data is available.
  """

  @dominance_threshold 0.80
  @max_examples 3
  @max_anomalies 50

  @separators ["", "-", "_"]

  # --- Public API ---

  @doc """
  Derive symbol patterns from market and describe data.

  Returns a map with per-type pattern analysis or nil if no markets.

  ## Parameters

    * `markets_data` — the `runtime.markets` map with `"markets"` key, or nil
    * `describe` — the `runtime.describe` map (for commonCurrencies), or nil
  """
  @spec derive(map() | nil, map() | nil) :: map() | nil
  def derive(nil, _describe), do: nil
  def derive(%{"markets" => nil}, _describe), do: nil
  def derive(%{"markets" => markets}, _describe) when map_size(markets) == 0, do: nil

  def derive(%{"markets" => markets}, describe) do
    type_groups = group_by_type(markets)

    type_patterns =
      type_groups
      |> Enum.map(fn {type, type_markets} -> {type, analyze_type(type_markets)} end)
      |> Enum.reject(fn {_type, analysis} -> is_nil(analysis) end)
      |> Map.new()

    currency_aliases = extract_currency_aliases(describe)

    Map.put(type_patterns, "currency_aliases", currency_aliases)
  end

  # --- Per-Type Analysis ---

  defp group_by_type(markets) do
    markets
    |> Enum.group_by(fn {_symbol, market} -> market["type"] end)
    |> Enum.reject(fn {type, _} -> is_nil(type) end)
    |> Map.new()
  end

  @doc false
  @spec analyze_type([{String.t(), map()}]) :: map() | nil
  def analyze_type([]), do: nil

  def analyze_type(markets) when is_list(markets) do
    classifications =
      Enum.map(markets, fn {_symbol, market} ->
        classify_market(market)
      end)

    structure = dominant_value(classifications, :id_structure)
    separator = dominant_value(classifications, :separator)
    detected_case = dominant_value(classifications, :case)
    suffix = dominant_suffix(classifications)

    # Anomalies are markets that don't match the dominant pattern
    anomaly_ids = collect_anomalies(classifications, structure, separator, detected_case, suffix)

    examples =
      markets
      |> Enum.take(@max_examples)
      |> Enum.map(fn {_symbol, m} ->
        %{
          "symbol" => m["symbol"],
          "id" => m["id"],
          "baseId" => m["baseId"],
          "quoteId" => m["quoteId"]
        }
      end)

    %{
      "id_structure" => structure,
      "separator" => separator,
      "case" => detected_case,
      "suffix" => suffix,
      "sample_count" => length(markets),
      "anomaly_count" => length(anomaly_ids),
      "anomalies" => Enum.take(anomaly_ids, @max_anomalies),
      "examples" => examples
    }
  end

  # --- Market Classification ---

  defp classify_market(market) do
    id = market["id"] || ""
    base_id = market["baseId"] || ""
    quote_id = market["quoteId"] || ""

    {structure, separator, suffix} = detect_id_structure(id, base_id, quote_id)
    detected_case = detect_case(id)

    %{
      id: id,
      id_structure: structure,
      separator: separator,
      suffix: suffix,
      case: detected_case
    }
  end

  # Try each separator to see if id starts with baseId + sep + quoteId
  defp detect_id_structure(id, _base_id, _quote_id) when byte_size(id) == 0 do
    {"opaque", nil, nil}
  end

  defp detect_id_structure(_id, base_id, _quote_id) when byte_size(base_id) == 0 do
    {"opaque", nil, nil}
  end

  defp detect_id_structure(id, base_id, quote_id) do
    # Try baseId + separator + quoteId (with optional suffix)
    result =
      Enum.find_value(@separators, fn sep ->
        core = base_id <> sep <> quote_id

        cond do
          id == core ->
            {"baseId_quoteId", sep, nil}

          String.starts_with?(id, core) and byte_size(id) > byte_size(core) ->
            suffix = String.slice(id, byte_size(core), byte_size(id) - byte_size(core))
            {"baseId_quoteId", sep, suffix}

          true ->
            nil
        end
      end)

    result || detect_alternative_structure(id, base_id, quote_id)
  end

  # Check for quoteId + sep + baseId (reverse order, e.g. upbit)
  # or baseId-only, or numeric/opaque patterns
  defp detect_alternative_structure(id, base_id, quote_id) do
    reverse_result =
      Enum.find_value(@separators, fn sep ->
        core = quote_id <> sep <> base_id

        cond do
          id == core ->
            {"quoteId_baseId", sep, nil}

          String.starts_with?(id, core) and byte_size(id) > byte_size(core) ->
            suffix = String.slice(id, byte_size(core), byte_size(id) - byte_size(core))
            {"quoteId_baseId", sep, suffix}

          true ->
            nil
        end
      end)

    cond do
      reverse_result != nil ->
        reverse_result

      id == base_id ->
        {"baseId_only", nil, nil}

      numeric?(id) ->
        {"numeric", nil, nil}

      true ->
        {"opaque", nil, nil}
    end
  end

  defp numeric?(str) do
    case Integer.parse(str) do
      {_n, ""} -> true
      _ -> String.starts_with?(str, "@") and numeric?(String.slice(str, 1, byte_size(str)))
    end
  end

  # --- Case Detection ---

  defp detect_case(id) when byte_size(id) == 0, do: nil

  defp detect_case(id) do
    # Only check alphabetic characters
    alpha_chars = String.replace(id, ~r/[^a-zA-Z]/, "")

    cond do
      byte_size(alpha_chars) == 0 -> nil
      alpha_chars == String.upcase(alpha_chars) -> "upper"
      alpha_chars == String.downcase(alpha_chars) -> "lower"
      true -> "mixed"
    end
  end

  # --- Dominant Pattern Detection ---

  # Count dominant against ALL classifications (including nil), not just non-nil values.
  # Without this, sparse fields inflate dominance (e.g., 1 letter ID in 284 numeric IDs = 100%).
  defp dominant_value(classifications, field) do
    total = length(classifications)

    frequencies =
      classifications
      |> Enum.map(&Map.get(&1, field))
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()

    find_dominant(frequencies, total)
  end

  defp find_dominant(frequencies, total) when map_size(frequencies) == 0 or total == 0, do: nil

  defp find_dominant(frequencies, total) do
    {value, count} = Enum.max_by(frequencies, fn {_v, c} -> c end)

    if count / total >= @dominance_threshold do
      value
    end
  end

  # Suffix detection: find the most common non-nil suffix if it dominates
  defp dominant_suffix(classifications) do
    suffixes =
      classifications
      |> Enum.map(& &1.suffix)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(suffixes) do
      nil
    else
      frequencies = Enum.frequencies(suffixes)
      {value, count} = Enum.max_by(frequencies, fn {_v, c} -> c end)

      if count / length(classifications) >= @dominance_threshold do
        value
      end
    end
  end

  # --- Anomaly Collection ---

  defp collect_anomalies(classifications, dominant_structure, dominant_separator, dominant_case, dominant_suffix) do
    classifications
    |> Enum.filter(fn c ->
      (dominant_structure != nil and c.id_structure != dominant_structure) or
        (dominant_separator != nil and c.separator != dominant_separator) or
        (dominant_case != nil and c.case != dominant_case) or
        (dominant_suffix != nil and c.suffix != dominant_suffix)
    end)
    |> Enum.map(& &1.id)
  end

  # --- Currency Aliases ---

  defp extract_currency_aliases(nil), do: %{}
  defp extract_currency_aliases(%{"commonCurrencies" => cc}) when is_map(cc), do: cc
  defp extract_currency_aliases(_), do: %{}
end

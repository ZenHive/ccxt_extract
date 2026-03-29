defmodule CcxtExtract.PublicExchanges do
  @moduledoc """
  Classify exchanges by credential requirements from describe() data.

  Reads the per-exchange describe() JSON files (from Task 6) and classifies
  each exchange by its credential pattern and whether it advertises
  `fetchMarkets` capability (`has.fetchMarkets == true`). This feeds into
  Task 8b, which will verify actual `loadMarkets()` callability at runtime.

  Also groups exchanges by credential pattern (e.g., `["apiKey", "secret"]`)
  for downstream analysis.

  ## Usage

      {:ok, analysis} = CcxtExtract.PublicExchanges.extract()
      CcxtExtract.PublicExchanges.write!(analysis)
  """

  @describe_dir "discoveries/describe"
  @output_file "discoveries/public_exchanges.json"

  @doc """
  Read all per-exchange describe JSON files and classify by credential requirements.

  Returns `{:ok, analysis}` or `{:error, {:missing_input, path}}` if the
  describe directory doesn't exist or has no manifest.
  """
  @spec extract() :: {:ok, map()} | {:error, {:missing_input, String.t()}}
  def extract do
    manifest_path = CcxtExtract.Paths.priv(Path.join(@describe_dir, "_manifest.json"))

    with {:ok, manifest} <- read_json(manifest_path) do
      describe_dir = CcxtExtract.Paths.priv(@describe_dir)

      exchanges = Enum.map(manifest["exchanges"], &load_exchange_describe(describe_dir, &1))

      {:ok, analyze(exchanges)}
    end
  end

  @doc """
  Classify exchanges by credential requirements and market listing capability.

  Pure function — takes a list of `{id, describe_map}` tuples.
  Returns a complete analysis map.
  """
  @spec analyze([{String.t(), map()}]) :: map()
  def analyze(exchanges) do
    classified =
      exchanges
      |> Enum.map(fn {id, describe} -> classify_exchange(id, describe) end)
      |> Enum.sort_by(& &1["id"])

    credential_patterns = build_credential_patterns(classified)
    advertise_count = Enum.count(classified, & &1["has_fetch_markets"])
    fully_public_count = Enum.count(classified, &(&1["credential_pattern"] == []))

    %{
      "extracted_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "exchange_count" => length(classified),
      "summary" => %{
        "all_have_fetch_markets" => advertise_count == length(classified),
        "credential_pattern_count" => length(credential_patterns),
        "fully_public_count" => fully_public_count,
        "fetch_markets_advertised_count" => advertise_count
      },
      "credential_patterns" => credential_patterns,
      "exchanges" => classified
    }
  end

  @doc """
  Write analysis to `priv/discoveries/public_exchanges.json`.
  """
  @spec write!(map(), String.t()) :: :ok
  def write!(analysis, output_path \\ CcxtExtract.Paths.priv(@output_file)) do
    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, Jason.encode!(analysis, pretty: true))
    :ok
  end

  # Load a single exchange's describe data — raises if file is missing
  defp load_exchange_describe(describe_dir, id) do
    path = Path.join(describe_dir, "#{id}.json")

    case read_json(path) do
      {:ok, data} ->
        {id, data["describe"]}

      {:error, {:missing_input, _}} ->
        raise "Missing describe file for exchange #{id}: #{path}\nRun `mix ccxt_extract.describe` to regenerate."
    end
  end

  # Classify a single exchange by its credential requirements
  defp classify_exchange(id, describe) do
    required_credentials = describe["requiredCredentials"] || %{}
    has = describe["has"] || %{}

    credential_pattern =
      required_credentials
      |> Enum.filter(fn {_k, v} -> v == true end)
      |> Enum.map(fn {k, _v} -> k end)
      |> Enum.sort()

    %{
      "id" => id,
      "has_fetch_markets" => has["fetchMarkets"] == true,
      "required_credentials" => required_credentials,
      "credential_pattern" => credential_pattern
    }
  end

  # Group exchanges by credential pattern, sorted by count descending
  defp build_credential_patterns(classified) do
    classified
    |> Enum.group_by(& &1["credential_pattern"])
    |> Enum.map(fn {pattern, exchanges} ->
      %{
        "pattern" => pattern,
        "count" => length(exchanges),
        "exchanges" => exchanges |> Enum.map(& &1["id"]) |> Enum.sort()
      }
    end)
    |> Enum.sort_by(&{-&1["count"], &1["pattern"]})
  end

  # Read and decode a JSON file
  defp read_json(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, Jason.decode!(content)}
      {:error, :enoent} -> {:error, {:missing_input, path}}
    end
  end
end

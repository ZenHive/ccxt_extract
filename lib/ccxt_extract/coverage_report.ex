defmodule CcxtExtract.CoverageReport do
  @moduledoc """
  Analyze extraction coverage across all exchanges and data sources.

  Reads existing JSON outputs from all extraction phases and reports
  per-exchange and global coverage. Pure analysis — no QuickBEAM/OXC needed.

  Ten coverage layers are checked per exchange:

  - **describe** — runtime describe() data from QuickBEAM
  - **load_markets** — loadMarkets() results from QuickBEAM
  - **class_hierarchy** — class/method data from OXC
  - **methods_rest** — REST method inventory from OXC
  - **methods_ws** — WS method inventory from OXC (pro exchanges only)
  - **sign_method** — sign() AST body from OXC
  - **handle_errors** — handleErrors() AST body from OXC
  - **parse_methods** — parse*() AST bodies from OXC
  - **ws_methods** — watch*/handle* AST bodies from OXC (pro exchanges only)
  - **overrides** — method overrides for derived exchanges

  Layers that don't apply to an exchange (e.g., WS for non-pro exchanges)
  are excluded from scoring rather than counted as gaps.

  ## Usage

      {:ok, report} = CcxtExtract.CoverageReport.extract()
      CcxtExtract.CoverageReport.write!(report)
  """

  @output_file "discoveries/coverage_report.json"

  @layer_names ~w(
    describe load_markets class_hierarchy methods_rest methods_ws
    sign_method handle_errors parse_methods ws_methods overrides
  )

  @doc "Ordered list of coverage layer names."
  @spec layer_names() :: [String.t()]
  def layer_names, do: @layer_names

  # --- Public API ---

  @doc """
  Run the coverage analysis by reading all extraction outputs.

  Only `exchanges.json` is required — missing extraction files are reported
  as gaps rather than errors.

  ## Options

    * `:discoveries_dir` — override input directory (for testing)
    * `:scope` — `:all` (default) or a `MapSet` of exchange IDs from
      `CcxtExtract.TaskScope.parse_and_resolve!/3`. When narrowed, only
      in-scope exchanges are analyzed; inputs still load the full discovery
      aggregates (layer checks look up by ID, so unused entries are benign).
  """
  @spec extract(keyword()) :: {:ok, map()} | {:error, CcxtExtract.JsonIO.read_error()}
  def extract(opts \\ []) do
    dir = Keyword.get(opts, :discoveries_dir, CcxtExtract.Paths.priv("discoveries"))
    scope = Keyword.get(opts, :scope, :all)
    exchanges_path = Path.join(dir, "exchanges.json")

    with {:ok, exchanges_data} <- CcxtExtract.JsonIO.read_json(exchanges_path) do
      exchanges = CcxtExtract.TaskScope.filter_entries(exchanges_data["exchanges"], scope, "id")
      inputs = load_all_inputs(dir)
      {:ok, analyze(exchanges, inputs)}
    end
  end

  @doc """
  Analyze coverage for a list of exchanges given preloaded inputs.

  Pure function — no I/O. This is the core testable entry point.
  """
  @spec analyze([map()], map()) :: map()
  def analyze(exchanges, inputs) do
    exchange_reports =
      exchanges
      |> Enum.map(&exchange_coverage(&1, inputs))
      |> Enum.sort_by(& &1["id"])

    summary = build_summary(exchange_reports, inputs)

    gaps_summary =
      exchange_reports
      |> Enum.filter(&(&1["gaps"] != []))
      |> Enum.map(&%{"id" => &1["id"], "gap_count" => length(&1["gaps"]), "gaps" => &1["gaps"]})
      |> Enum.sort_by(&{-&1["gap_count"], &1["id"]})

    %{
      "extracted_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "exchange_count" => length(exchanges),
      "summary" => summary,
      "exchanges" => exchange_reports,
      "gaps_summary" => gaps_summary
    }
  end

  @doc """
  Compute coverage for a single exchange. Pure function.

  Returns a map with per-layer status, coverage score, and gap list.
  """
  @spec exchange_coverage(map(), map()) :: map()
  def exchange_coverage(exchange, inputs) do
    id = exchange["id"]
    is_alias = exchange["alias"] == true
    has_pro = exchange["pro"] == true

    # Compute whether this exchange is derived (has a parent in overrides)
    is_derived = MapSet.member?(inputs.overrides_ids, id)

    layers = %{
      "describe" => check_describe(id, is_alias, inputs),
      "load_markets" => check_load_markets(id, is_alias, inputs),
      "class_hierarchy" => check_class_hierarchy(id, inputs),
      "methods_rest" => check_methods_rest(id, inputs),
      "methods_ws" => check_methods_ws(id, has_pro, inputs),
      "sign_method" => check_sign_method(id, is_alias, inputs),
      "handle_errors" => check_handle_errors(id, is_alias, inputs),
      "parse_methods" => check_parse_methods(id, is_alias, inputs),
      "ws_methods" => check_ws_methods(id, has_pro, inputs),
      "overrides" => check_overrides(id, is_derived, inputs)
    }

    {score, max} = compute_score(layers)

    pct =
      if max > 0,
        do: Float.round(score / max * 100, 1),
        else: 0.0

    gaps =
      layers
      |> Enum.reject(fn {_name, layer} -> layer["present"] or not layer["applicable"] end)
      |> Enum.map(fn {name, layer} -> "#{name}: #{layer["reason"]}" end)
      |> Enum.sort()

    %{
      "id" => id,
      "is_alias" => is_alias,
      "has_pro" => has_pro,
      "layers" => layers,
      "coverage_score" => score,
      "coverage_max" => max,
      "coverage_pct" => pct,
      "gaps" => gaps
    }
  end

  @doc """
  Write coverage report to JSON file.

  Accepts `:tier_scope` option — the JSON-serialisable value from
  `CcxtExtract.TaskScope.parse_and_resolve!/3`, stamped into the report
  envelope as `tier_scope`.
  """
  @spec write!(map(), keyword()) :: :ok
  def write!(report, opts \\ []),
    do: CcxtExtract.DiscoveryWriter.write!(report, CcxtExtract.Paths.priv(@output_file), opts)

  # --- Input Loading ---

  # Loads all extraction JSON files from the discoveries directory into a lookup struct
  @spec load_all_inputs(String.t()) :: map()
  defp load_all_inputs(dir) do
    missing_files = []

    {describe_ids, missing_files} = load_describe_manifest(dir, missing_files)
    {lm_succeeded, lm_failed, missing_files} = load_markets_manifest(dir, missing_files)
    {class_ids, class_lookup, missing_files} = load_class_hierarchy(dir, missing_files)
    {methods_rest_ids, missing_files} = load_exchange_ids(dir, "methods_rest.json", missing_files)
    {methods_ws_ids, missing_files} = load_exchange_ids(dir, "methods_ws.json", missing_files)
    {sign_lookup, missing_files} = load_exchange_lookup(dir, "sign_methods.json", missing_files)
    {he_lookup, missing_files} = load_exchange_lookup(dir, "handle_errors.json", missing_files)
    {pm_lookup, missing_files} = load_exchange_lookup(dir, "parse_methods.json", missing_files)
    {ws_methods_lookup, missing_files} = load_exchange_lookup(dir, "ws_methods.json", missing_files)
    {overrides_ids, missing_files} = load_exchange_ids(dir, "overrides.json", missing_files)

    %{
      describe_ids: describe_ids,
      load_markets_succeeded: lm_succeeded,
      load_markets_failed: lm_failed,
      class_ids: class_ids,
      class_lookup: class_lookup,
      methods_rest_ids: methods_rest_ids,
      methods_ws_ids: methods_ws_ids,
      sign_lookup: sign_lookup,
      handle_errors_lookup: he_lookup,
      parse_methods_lookup: pm_lookup,
      ws_methods_lookup: ws_methods_lookup,
      overrides_ids: overrides_ids,
      missing_files: Enum.reverse(missing_files)
    }
  end

  # --- Layer Checks ---

  # Each returns %{"present" => bool, "applicable" => bool, "reason" => string | nil}

  defp layer(present, applicable, reason \\ nil),
    do: %{"present" => present, "applicable" => applicable, "reason" => reason}

  defp check_describe(_id, true = _is_alias, _inputs), do: layer(false, false, "alias")

  defp check_describe(id, _is_alias, inputs) do
    if MapSet.member?(inputs.describe_ids, id),
      do: layer(true, true),
      else: layer(false, true, "not_extracted")
  end

  defp check_load_markets(_id, true = _is_alias, _inputs), do: layer(false, false, "alias")

  defp check_load_markets(id, _is_alias, inputs) do
    cond do
      MapSet.member?(inputs.load_markets_succeeded, id) -> layer(true, true)
      MapSet.member?(inputs.load_markets_failed, id) -> layer(false, true, "failed")
      true -> layer(false, true, "not_extracted")
    end
  end

  defp check_class_hierarchy(id, inputs) do
    if MapSet.member?(inputs.class_ids, id),
      do: layer(true, true),
      else: layer(false, true, "not_found")
  end

  defp check_methods_rest(id, inputs) do
    if MapSet.member?(inputs.methods_rest_ids, id),
      do: layer(true, true),
      else: layer(false, true, "not_found")
  end

  defp check_methods_ws(id, has_pro, inputs) do
    has_data = MapSet.member?(inputs.methods_ws_ids, id)

    cond do
      has_data -> layer(true, true)
      has_pro -> layer(false, true, "not_found")
      true -> layer(false, false, "no_ws_exchange")
    end
  end

  defp check_sign_method(_id, true = _is_alias, _inputs), do: layer(false, false, "alias")

  defp check_sign_method(id, _is_alias, inputs) do
    case Map.get(inputs.sign_lookup, id) do
      nil -> layer(false, true, "not_found")
      entry -> if entry["sign"], do: layer(true, true), else: layer(false, true, "no_sign_method")
    end
  end

  defp check_handle_errors(_id, true = _is_alias, _inputs), do: layer(false, false, "alias")

  defp check_handle_errors(id, _is_alias, inputs) do
    case Map.get(inputs.handle_errors_lookup, id) do
      nil -> layer(false, true, "not_found")
      entry -> if entry["handle_errors"], do: layer(true, true), else: layer(false, true, "no_handle_errors")
    end
  end

  defp check_parse_methods(_id, true = _is_alias, _inputs), do: layer(false, false, "alias")

  defp check_parse_methods(id, _is_alias, inputs) do
    case Map.get(inputs.parse_methods_lookup, id) do
      nil ->
        layer(false, true, "not_found")

      entry ->
        if (entry["parse_method_count"] || 0) > 0, do: layer(true, true), else: layer(false, true, "no_parse_methods")
    end
  end

  defp check_ws_methods(id, has_pro, inputs) do
    case Map.get(inputs.ws_methods_lookup, id) do
      nil ->
        if has_pro, do: layer(false, true, "not_found"), else: layer(false, false, "no_ws_exchange")

      entry ->
        if (entry["ws_method_count"] || 0) > 0, do: layer(true, true), else: layer(false, true, "no_ws_methods")
    end
  end

  defp check_overrides(_id, false = _is_derived, _inputs), do: layer(false, false, "root_exchange")

  # When is_derived is true, the exchange is already confirmed in overrides_ids
  defp check_overrides(_id, _is_derived, _inputs), do: layer(true, true)

  # --- Scoring ---

  # Counts applicable layers as max, present layers as score
  defp compute_score(layers) do
    Enum.reduce(layers, {0, 0}, fn {_name, layer}, {score, max} ->
      score_layer({score, max}, layer["applicable"], layer["present"])
    end)
  end

  defp score_layer(acc, false = _applicable, _present), do: acc
  defp score_layer({score, max}, true = _applicable, true = _present), do: {score + 1, max + 1}
  defp score_layer({score, max}, true = _applicable, _present), do: {score, max + 1}

  # --- Summary ---

  defp build_summary(exchange_reports, inputs) do
    total = length(exchange_reports)

    full = Enum.count(exchange_reports, &(&1["coverage_pct"] == 100.0))
    no_cov = Enum.count(exchange_reports, &(&1["coverage_pct"] == 0.0))
    partial = total - full - no_cov

    avg_pct =
      if total > 0 do
        exchange_reports
        |> Enum.map(& &1["coverage_pct"])
        |> Enum.sum()
        |> Kernel./(total)
        |> Float.round(1)
      else
        0.0
      end

    per_layer =
      Map.new(@layer_names, fn name ->
        applicable = Enum.count(exchange_reports, & &1["layers"][name]["applicable"])
        present = Enum.count(exchange_reports, & &1["layers"][name]["present"])
        missing = applicable - present
        {name, %{"present" => present, "missing" => missing, "applicable" => applicable}}
      end)

    %{
      "full_coverage" => full,
      "partial_coverage" => partial,
      "no_coverage" => no_cov,
      "avg_coverage_pct" => avg_pct,
      "per_layer" => per_layer,
      "missing_files" => inputs.missing_files
    }
  end

  # --- Private: File Loading ---

  defp load_describe_manifest(dir, missing) do
    path = Path.join([dir, "describe", "_manifest.json"])

    case CcxtExtract.JsonIO.read_json(path) do
      {:ok, data} ->
        ids = data["exchanges"] |> List.wrap() |> MapSet.new()
        {ids, missing}

      {:error, _} ->
        {MapSet.new(), ["describe/_manifest.json" | missing]}
    end
  end

  defp load_markets_manifest(dir, missing) do
    path = Path.join([dir, "load_markets", "_manifest.json"])

    case CcxtExtract.JsonIO.read_json(path) do
      {:ok, data} ->
        succeeded = data["succeeded"] |> List.wrap() |> MapSet.new()

        failed =
          data["failed"]
          |> List.wrap()
          |> MapSet.new(fn
            %{"id" => id} -> id
            id when is_binary(id) -> id
          end)

        {succeeded, failed, missing}

      {:error, _} ->
        {MapSet.new(), MapSet.new(), ["load_markets/_manifest.json" | missing]}
    end
  end

  defp load_class_hierarchy(dir, missing) do
    path = Path.join(dir, "class_hierarchy.json")

    case CcxtExtract.JsonIO.read_json(path) do
      {:ok, data} ->
        classes = data["classes"] || []
        ids = MapSet.new(classes, & &1["id"])
        lookup = Map.new(classes, &{&1["id"], &1})
        {ids, lookup, missing}

      {:error, _} ->
        {MapSet.new(), %{}, ["class_hierarchy.json" | missing]}
    end
  end

  # Loads a JSON file with an "exchanges" array and extracts IDs into a MapSet
  defp load_exchange_ids(dir, filename, missing) do
    path = Path.join(dir, filename)

    case CcxtExtract.JsonIO.read_json(path) do
      {:ok, data} ->
        ids =
          data["exchanges"]
          |> List.wrap()
          |> MapSet.new(& &1["id"])

        {ids, missing}

      {:error, _} ->
        {MapSet.new(), [filename | missing]}
    end
  end

  # Loads a JSON file with an "exchanges" array and builds an id => entry lookup map
  defp load_exchange_lookup(dir, filename, missing) do
    path = Path.join(dir, filename)

    case CcxtExtract.JsonIO.read_json(path) do
      {:ok, data} ->
        lookup =
          data["exchanges"]
          |> List.wrap()
          |> Map.new(&{&1["id"], &1})

        {lookup, missing}

      {:error, _} ->
        {%{}, [filename | missing]}
    end
  end
end

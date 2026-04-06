defmodule CcxtExtract.Overrides do
  @moduledoc """
  Extract method override data for exchanges that extend other exchanges.

  For each exchange with a non-Exchange parent, identifies:
  - **Overridden methods**: defined in child AND an ancestor (full AST body included)
  - **New methods**: defined in child but NOT in any ancestor (full AST body included)
  - **Inherited methods**: defined in ancestors but NOT overridden (names only)

  Uses `CcxtExtract.Classes.extract/0` for hierarchy data, then re-parses
  only derived class TS files to get method AST bodies.

  Reuses parameter and type extraction from `CcxtExtract.Methods`.

  ## Usage

      {:ok, exchanges, stats} = CcxtExtract.Overrides.extract()
      CcxtExtract.Overrides.write!(exchanges)
  """

  require Logger

  @output_file "overrides.json"

  @doc """
  Extract override data for all derived exchanges.

  Runs `Classes.extract/0` to get hierarchy, builds ancestor method sets,
  then re-parses derived class TS files to extract method bodies.

  Returns `{:ok, exchanges, stats}` where stats includes `:errors` (override parse
  errors), `:class_errors`, and `:class_skipped` from the hierarchy extraction phase.
  """
  @spec extract() :: {:ok, [map()], map()}
  def extract do
    {:ok, classes, class_stats} = CcxtExtract.Classes.extract()

    by_node_key = Map.new(classes, &{&1["node_key"], &1})
    ancestor_methods = build_ancestor_methods(classes, by_node_key)

    derived =
      Enum.filter(classes, fn c ->
        pk = c["parent_key"]
        pk != nil and pk != "Exchange"
      end)

    {exchanges, errors} = extract_derived(derived, ancestor_methods, by_node_key)
    sorted = Enum.sort_by(exchanges, & &1["id"])

    stats = %{
      errors: Enum.reverse(errors),
      class_errors: class_stats.errors,
      class_skipped: class_stats.skipped
    }

    {:ok, sorted, stats}
  end

  @doc """
  Write extracted override data to `priv/discoveries/overrides.json`.
  """
  @spec write!([map()], String.t()) :: %{
          with_overrides: non_neg_integer(),
          total_overrides: non_neg_integer(),
          total_new: non_neg_integer()
        }
  def write!(exchanges, output_path \\ CcxtExtract.Paths.priv(Path.join("discoveries", @output_file))) do
    File.mkdir_p!(Path.dirname(output_path))

    with_overrides = Enum.count(exchanges, fn e -> e["override_count"] > 0 end)
    total_overrides = Enum.sum(Enum.map(exchanges, & &1["override_count"]))
    total_new = Enum.sum(Enum.map(exchanges, & &1["new_method_count"]))

    output = %{
      "extracted_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "count" => length(exchanges),
      "with_overrides" => with_overrides,
      "total_overrides" => total_overrides,
      "total_new_methods" => total_new,
      "exchanges" => exchanges
    }

    json = Jason.encode!(output, pretty: true)
    File.write!(output_path, json)

    %{with_overrides: with_overrides, total_overrides: total_overrides, total_new: total_new}
  end

  @doc """
  Build accumulated method sets for all classes.

  For each class, computes the union of its own methods and all ancestor methods.
  The result maps `node_key` to a `MapSet` of all methods available from that class
  and its ancestors. Used for override detection: a child's ancestors are
  `accumulated[parent_key]`.

  Memoized via fold accumulator. Circular references are guarded against.
  """
  @spec build_ancestor_methods([map()], %{String.t() => map()}) :: %{String.t() => MapSet.t()}
  def build_ancestor_methods(classes, by_node_key) do
    Enum.reduce(classes, %{}, fn class, memo ->
      {_methods, memo} = accumulate_methods(class["node_key"], by_node_key, memo, MapSet.new())
      memo
    end)
  end

  @doc """
  Extract specific method bodies from a TypeScript file.

  Parses the file with OXC, finds the default-exported class, and extracts
  full method data only for methods in `method_names`.

  Returns `{:ok, methods_map}` or `{:error, reason}`.
  """
  @spec extract_method_bodies(String.t(), String.t(), MapSet.t()) ::
          {:ok, %{String.t() => map()}} | {:error, term()}
  def extract_method_bodies(path, filename, method_names) do
    source = File.read!(path)

    case OXC.parse(source, filename) do
      {:ok, ast} ->
        {:ok, methods_from_ast(ast, method_names)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Extract matching methods from a parsed AST's default-exported class.
  defp methods_from_ast(ast, method_names) do
    export = Enum.find(ast.body, &(&1.type == "ExportDefaultDeclaration"))

    if export && export.declaration && Map.get(export.declaration, :body) do
      export.declaration.body.body
      |> Enum.filter(&method_match?(&1, method_names))
      |> Map.new(fn m -> {m.key.name, CcxtExtract.MethodAST.extract(m)} end)
    else
      %{}
    end
  end

  defp method_match?(member, method_names) do
    member.type == "MethodDefinition" && MapSet.member?(method_names, member.key.name)
  end

  # Recursively accumulate all methods for a node_key (own + ancestors).
  # Returns {accumulated_set, updated_memo}.
  @spec accumulate_methods(String.t(), map(), map(), MapSet.t()) :: {MapSet.t(), map()}
  defp accumulate_methods(node_key, by_node_key, memo, visited) do
    cond do
      Map.has_key?(memo, node_key) ->
        {memo[node_key], memo}

      MapSet.member?(visited, node_key) ->
        Logger.warning("Circular inheritance detected at #{node_key}")
        {MapSet.new(), Map.put(memo, node_key, MapSet.new())}

      true ->
        accumulate_for_class(node_key, by_node_key, memo, visited)
    end
  end

  # Accumulate methods for a class not yet in the memo.
  defp accumulate_for_class(node_key, by_node_key, memo, visited) do
    class = Map.get(by_node_key, node_key)
    parent_key = class && class["parent_key"]

    if is_nil(class) or is_nil(parent_key) or parent_key == "Exchange" do
      own = if class, do: MapSet.new(class["methods"]), else: MapSet.new()
      {own, Map.put(memo, node_key, own)}
    else
      visited = MapSet.put(visited, node_key)

      {parent_accumulated, memo} =
        accumulate_methods(parent_key, by_node_key, memo, visited)

      own = MapSet.new(class["methods"])
      accumulated = MapSet.union(parent_accumulated, own)
      {accumulated, Map.put(memo, node_key, accumulated)}
    end
  end

  # Extract override data for all derived classes.
  # Returns {exchanges, errors}.
  @spec extract_derived([map()], map(), map()) :: {[map()], list()}
  defp extract_derived(derived, ancestor_methods, by_node_key) do
    ts_src = CcxtExtract.Paths.ts_src()

    Enum.reduce(derived, {[], []}, fn class, {exchanges, errors} ->
      case extract_one(class, ancestor_methods, by_node_key, ts_src) do
        {:ok, exchange} -> {[exchange | exchanges], errors}
        {:error, file, reason} -> {exchanges, [{file, reason} | errors]}
      end
    end)
  end

  # Extract override data for a single derived class.
  defp extract_one(class, ancestor_methods, by_node_key, ts_src) do
    own = MapSet.new(class["methods"])
    ancestors = Map.get(ancestor_methods, class["parent_key"], MapSet.new())

    overridden_names = MapSet.intersection(own, ancestors)
    new_names = MapSet.difference(own, ancestors)
    inherited = ancestors |> MapSet.difference(own) |> MapSet.to_list() |> Enum.sort()

    subdir = if class["type"] == "ws", do: "pro", else: ""
    path = Path.join([ts_src, subdir, class["file"]])

    case extract_method_bodies(path, class["file"], own) do
      {:ok, all_bodies} ->
        {:ok, build_exchange_map(class, all_bodies, own, overridden_names, new_names, inherited, by_node_key)}

      {:error, reason} ->
        Logger.warning("Failed to parse #{class["file"]} for override extraction: #{inspect(reason)}")
        {:error, class["file"], reason}
    end
  end

  # Build the per-exchange output map from computed override sets.
  defp build_exchange_map(class, all_bodies, own, overridden_names, new_names, inherited, by_node_key) do
    overrides = Map.filter(all_bodies, fn {name, _} -> MapSet.member?(overridden_names, name) end)
    new_methods = Map.filter(all_bodies, fn {name, _} -> MapSet.member?(new_names, name) end)

    parent_class = Map.get(by_node_key, class["parent_key"])
    extends_name = if parent_class, do: parent_class["id"], else: class["extends_resolved"]

    %{
      "id" => class["id"],
      "type" => class["type"],
      "file" => class["file"],
      "node_key" => class["node_key"],
      "parent_key" => class["parent_key"],
      "extends" => extends_name,
      "own_method_count" => MapSet.size(own),
      "override_count" => map_size(overrides),
      "new_method_count" => map_size(new_methods),
      "inherited_count" => length(inherited),
      "overrides" => overrides,
      "new_methods" => new_methods,
      "inherited_methods" => inherited
    }
  end
end

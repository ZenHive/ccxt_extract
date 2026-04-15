defmodule CcxtExtract.Classes do
  @moduledoc """
  Extract class hierarchy from CCXT TypeScript source via OXC.

  Parses all `.ts` files in the REST and WS source directories, extracts
  class name, superclass, and method list from each, then builds the full
  inheritance tree with resolved import aliases.

  ## Usage

      {:ok, classes, stats} = CcxtExtract.Classes.extract()
      CcxtExtract.Classes.write!(classes)
  """

  require Logger

  @output_file "class_hierarchy.json"

  @doc """
  Extract class hierarchy from CCXT TypeScript source files.

  Scans `priv/ccxt/ts/src/` (REST) and `priv/ccxt/ts/src/pro/` (WS),
  parses each `.ts` file with OXC, and extracts class metadata.

  Returns `{:ok, classes, stats}` where stats contains `:skipped` and `:errors` lists.

  Raises if TS source is not available (run `mix ccxt_extract.setup` first).
  """
  @spec extract() :: {:ok, [map()], map()}
  def extract do
    ts_src = CcxtExtract.Paths.ts_src()

    if !File.dir?(ts_src) do
      raise "CCXT TypeScript source not found at #{ts_src}. Run `mix ccxt_extract.setup` first."
    end

    rest_files = Path.wildcard(Path.join(ts_src, "*.ts"))
    ws_files = Path.wildcard(Path.join(ts_src, "pro/*.ts"))

    if rest_files == [] do
      raise "No .ts files found in #{ts_src}. CCXT source may be incomplete — run `mix ccxt_extract.setup`."
    end

    rest_results = Enum.map(rest_files, &parse_file(&1, "rest"))
    ws_results = Enum.map(ws_files, &parse_file(&1, "ws"))

    {classes, skipped, errors} =
      Enum.reduce(rest_results ++ ws_results, {[], [], []}, fn
        {:ok, class}, {ok, skip, err} -> {[class | ok], skip, err}
        {:skip, file}, {ok, skip, err} -> {ok, [file | skip], err}
        {:error, file, reason}, {ok, skip, err} -> {ok, skip, [{file, reason} | err]}
      end)

    for {file, reason} <- errors do
      Logger.warning("Failed to parse #{file}: #{inspect(reason)}")
    end

    sorted = Enum.sort_by(classes, & &1["id"])

    {:ok, sorted, %{skipped: Enum.reverse(skipped), errors: Enum.reverse(errors)}}
  end

  @doc """
  Write extracted classes and inheritance tree to `priv/discoveries/class_hierarchy.json`.

  Creates the output directory if needed. Wraps class list in a metadata
  envelope with timestamp, count, inheritance tree, and WS counterpart list.

  Accepts pre-computed `tree` and `ws_counterparts` to avoid recomputation
  when the caller already has them (e.g., the mix task computes them for display).
  """
  @spec write!([map()], String.t()) :: :ok
  def write!(classes, output_path \\ CcxtExtract.Paths.priv(Path.join("discoveries", @output_file))) do
    write!(classes, build_tree(classes), find_ws_counterparts(classes), output_path)
  end

  @doc false
  @spec write!([map()], map(), [String.t()], String.t()) :: :ok
  def write!(
        classes,
        tree,
        ws_counterparts,
        output_path \\ CcxtExtract.Paths.priv(Path.join("discoveries", @output_file))
      ) do
    File.mkdir_p!(Path.dirname(output_path))

    output = %{
      "extracted_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "count" => length(classes),
      "classes" => classes,
      "tree" => tree,
      "ws_counterparts" => ws_counterparts
    }

    json = Jason.encode!(output, pretty: true)
    File.write!(output_path, json)
    :ok
  end

  @doc """
  Build inheritance tree from class list.

  Groups classes by `parent_key`, with `node_key` as children.
  Returns a map where each key is a parent identifier and each value
  is a sorted list of child `node_key` strings.

      build_tree([
        %{"node_key" => "rest:binance", "parent_key" => "Exchange"},
        %{"node_key" => "rest:binanceus", "parent_key" => "rest:binance"},
        %{"node_key" => "ws:binance", "parent_key" => "rest:binance"}
      ])
      #=> %{"Exchange" => ["rest:binance"],
      #     "rest:binance" => ["rest:binanceus", "ws:binance"]}
  """
  @spec build_tree([map()]) :: map()
  def build_tree(classes) do
    classes
    |> Enum.reject(&is_nil(&1["parent_key"]))
    |> Enum.group_by(& &1["parent_key"], & &1["node_key"])
    |> Map.new(fn {parent, children} -> {parent, children |> Enum.uniq() |> Enum.sort()} end)
  end

  @doc """
  Find exchanges that have both REST and WS implementations.

  Returns a sorted list of exchange IDs that appear in both `priv/ccxt/ts/src/`
  and `priv/ccxt/ts/src/pro/`.
  """
  @spec find_ws_counterparts([map()]) :: [String.t()]
  def find_ws_counterparts(classes) do
    rest_ids = classes |> Enum.filter(&(&1["type"] == "rest")) |> MapSet.new(& &1["id"])
    ws_ids = classes |> Enum.filter(&(&1["type"] == "ws")) |> MapSet.new(& &1["id"])

    rest_ids
    |> MapSet.intersection(ws_ids)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  @doc """
  Parse a single TypeScript file and extract class metadata.

  Returns `{:ok, class_map}`, `{:skip, filename}` if no exported class,
  or `{:error, filename, reason}` on parse failure.
  """
  @spec parse_file(String.t(), String.t()) :: {:ok, map()} | {:skip, String.t()} | {:error, String.t(), term()}
  def parse_file(path, type) do
    source = File.read!(path)
    filename = Path.basename(path)

    case OXC.parse(source, filename) do
      {:ok, ast} ->
        aliases = build_import_aliases(ast, type)

        case extract_class(ast, filename, type, aliases) do
          nil -> {:skip, filename}
          class -> {:ok, class}
        end

      {:error, reason} ->
        {:error, filename, reason}
    end
  end

  @doc """
  Build a map of import aliases to their resolved class names.

  Extracts default import specifiers from `ImportDeclaration` nodes.
  Resolves the import source path to a class name and source type:

  - For WS files: `../binance.js` → `{"binance", "rest"}`, `./binance.js` → `{"binance", "ws"}`
  - For REST files: `./binance.js` → `{"binance", "rest"}` (same directory = same type)

  Returns `%{"binanceRest" => {"binance", "rest"}, ...}`
  """
  @spec build_import_aliases(map(), String.t()) :: map()
  def build_import_aliases(ast, current_type) do
    ast.body
    |> Enum.filter(&(&1.type == :import_declaration))
    |> Enum.flat_map(fn import_decl ->
      source_path = import_decl.source.value

      import_decl.specifiers
      |> Enum.filter(&(&1.type == :import_default_specifier))
      |> Enum.map(fn spec ->
        alias_name = spec.local.name
        {resolved_name, source_type} = resolve_import_path(source_path, current_type)
        {alias_name, {resolved_name, source_type}}
      end)
    end)
    |> Map.new()
  end

  @doc """
  Extract class info from a parsed AST.

  Looks for `ExportDefaultDeclaration` containing a class, then extracts
  class name, superclass, method list, and resolved parent identity.
  """
  @spec extract_class(map(), String.t(), String.t(), map()) :: map() | nil
  def extract_class(ast, filename, type, aliases) do
    export = Enum.find(ast.body, &(&1.type == :export_default_declaration))

    if export && export.declaration && Map.get(export.declaration, :body) do
      class = export.declaration
      class_name = if class.id, do: class.id.name

      extends_raw =
        cond do
          is_nil(class.superClass) -> nil
          Map.has_key?(class.superClass, :name) -> class.superClass.name
          true -> nil
        end

      {extends_resolved, parent_key} = resolve_extends(extends_raw, type, aliases)

      methods = extract_methods(class.body.body)
      id = class_name || Path.rootname(filename)
      node_key = "#{type}:#{id}"

      %{
        "id" => id,
        "node_key" => node_key,
        "class_name" => class_name,
        "extends_raw" => extends_raw,
        "extends_resolved" => extends_resolved,
        "parent_key" => parent_key,
        "type" => type,
        "file" => filename,
        "methods" => Enum.map(methods, & &1["name"]),
        "method_count" => length(methods),
        "method_details" => methods
      }
    end
  end

  @doc """
  Extract method metadata from class body members.

  Filters for `MethodDefinition` nodes and extracts name, async status,
  parameter count, and statement count.
  """
  @spec extract_methods([map()]) :: [map()]
  def extract_methods(members) do
    members
    |> Enum.filter(&(&1.type == :method_definition))
    |> Enum.map(fn m ->
      %{
        "name" => m.key.name,
        "async" => m.value.async,
        "params" => length(m.value.params),
        "statements" => length(m.value.body.body)
      }
    end)
  end

  # Resolve an import source path to {class_name, source_type}.
  # The meaning of "./" depends on which directory we're in:
  #   REST file + "./"  → same dir = REST parent
  #   WS file   + "./"  → same dir = WS parent
  #   WS file   + "../" → up one dir = REST parent
  defp resolve_import_path(source_path, current_type) do
    basename = source_path |> Path.basename() |> Path.rootname()

    cond do
      String.starts_with?(source_path, "../") -> {basename, "rest"}
      String.starts_with?(source_path, "./") -> {basename, current_type}
      true -> {basename, nil}
    end
  end

  # Resolve extends_raw through the import alias map.
  # Returns {extends_resolved, parent_key}.
  defp resolve_extends(nil, _type, _aliases), do: {nil, nil}

  defp resolve_extends("Exchange", _type, _aliases), do: {"Exchange", "Exchange"}

  defp resolve_extends(extends_raw, type, aliases) do
    case Map.get(aliases, extends_raw) do
      {resolved_name, parent_type} ->
        {resolved_name, "#{parent_type}:#{resolved_name}"}

      nil ->
        # No alias found — assume same type as current file
        {extends_raw, "#{type}:#{extends_raw}"}
    end
  end
end

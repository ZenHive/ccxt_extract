defmodule CcxtExtract.Pagination do
  @moduledoc """
  Extract pagination strategies from CCXT exchange TypeScript source files.

  CCXT uses four pagination strategies: Dynamic, Deterministic, Cursor, and
  Incremental. Each exchange's TS source calls `this.fetchPaginatedCall*`
  inside method bodies when pagination is enabled. This module walks the AST
  of each exchange file, finds those call expressions, and extracts the
  strategy type and strategy-specific parameters.

  ## Usage

      {:ok, exchanges, stats} = CcxtExtract.Pagination.extract()
      CcxtExtract.Pagination.write!(exchanges)
  """

  require Logger

  @output_file "pagination.json"

  @strategy_methods %{
    "fetchPaginatedCallDynamic" => "dynamic",
    "fetchPaginatedCallDeterministic" => "deterministic",
    "fetchPaginatedCallCursor" => "cursor",
    "fetchPaginatedCallIncremental" => "incremental"
  }

  @doc """
  Extract pagination strategies from all REST exchange TypeScript files.

  Parses each `.ts` file in `priv/ccxt/ts/src/` via OXC, walks method bodies
  to find `this.fetchPaginatedCall*` calls, and extracts strategy and parameters.

  Returns `{:ok, exchanges, stats}` where stats has `:skipped` and `:errors` lists.
  """
  @spec extract() :: {:ok, [map()], map()}
  def extract do
    ts_src = CcxtExtract.Paths.ts_src()

    if !File.dir?(ts_src) do
      raise "CCXT TypeScript source not found at #{ts_src}. Run `mix ccxt_extract.setup` first."
    end

    files = Path.wildcard(Path.join(ts_src, "*.ts"))

    if files == [] do
      raise "No .ts files found in #{ts_src}. CCXT source may be incomplete."
    end

    {exchanges, skipped, errors} =
      files
      |> Enum.map(&parse_file/1)
      |> Enum.reduce({[], [], []}, fn
        {:ok, exchange}, {ok, skip, err} -> {[exchange | ok], skip, err}
        {:skip, file}, {ok, skip, err} -> {ok, [file | skip], err}
        {:error, file, reason}, {ok, skip, err} -> {ok, skip, [{file, reason} | err]}
      end)

    for {file, reason} <- errors do
      Logger.warning("Failed to parse #{file}: #{inspect(reason)}")
    end

    sorted = Enum.sort_by(exchanges, & &1["id"])

    {:ok, sorted, %{skipped: Enum.reverse(skipped), errors: Enum.reverse(errors)}}
  end

  @doc """
  Write extracted pagination data to `priv/discoveries/pagination.json`.
  """
  @spec write!([map()], String.t()) :: :ok
  def write!(exchanges, output_path \\ CcxtExtract.Paths.priv(Path.join("discoveries", @output_file))) do
    File.mkdir_p!(Path.dirname(output_path))

    with_pagination = Enum.count(exchanges, fn e -> e["pagination_count"] > 0 end)
    total_entries = Enum.sum(Enum.map(exchanges, & &1["pagination_count"]))

    total_unresolved =
      exchanges
      |> Enum.map(fn e -> length(Map.get(e, "pagination_unresolved", [])) end)
      |> Enum.sum()

    output = %{
      "extracted_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "count" => length(exchanges),
      "with_pagination" => with_pagination,
      "total_entries" => total_entries,
      "total_unresolved" => total_unresolved,
      "exchanges" => exchanges
    }

    json = Jason.encode!(output, pretty: true)
    File.write!(output_path, json)
    :ok
  end

  @doc """
  Parse a single TypeScript file and extract pagination strategies.

  Returns `{:ok, exchange_map}`, `{:skip, filename}` if no exported class,
  or `{:error, filename, reason}` on parse failure.
  """
  @spec parse_file(String.t()) :: {:ok, map()} | {:skip, String.t()} | {:error, String.t(), term()}
  def parse_file(path) do
    source = File.read!(path)
    filename = Path.basename(path)

    case OXC.parse(source, filename) do
      {:ok, ast} ->
        case extract_from_ast(ast, filename) do
          nil -> {:skip, filename}
          exchange -> {:ok, exchange}
        end

      {:error, reason} ->
        {:error, filename, reason}
    end
  end

  @doc """
  Extract pagination strategies from a parsed AST.

  Finds the default-exported class, walks all method bodies to find
  `this.fetchPaginatedCall*` call expressions, and extracts the strategy
  type and strategy-specific parameters for each.

  Returns nil if no exported class is found.
  """
  @spec extract_from_ast(map(), String.t()) :: map() | nil
  def extract_from_ast(ast, filename) do
    export = Enum.find(ast.body, &(&1.type == "ExportDefaultDeclaration"))

    if export && export.declaration && Map.get(export.declaration, :body) do
      class = export.declaration
      class_name = if class.id, do: class.id.name, else: Path.rootname(filename)
      id = class_name

      {resolved, unresolved} =
        class.body.body
        |> Enum.filter(&(&1.type == "MethodDefinition"))
        |> Enum.flat_map(&walk_method_for_pagination/1)
        |> Enum.map(&extract_pagination_entry/1)
        |> split_resolved_unresolved()

      pagination_map = group_entries(resolved)
      resolved_count = Enum.sum(Enum.map(pagination_map, fn {_, entries} -> length(entries) end))
      entry_count = resolved_count + length(unresolved)

      result = %{
        "id" => id,
        "class_name" => class_name,
        "file" => filename,
        "pagination_count" => entry_count,
        "pagination" => pagination_map
      }

      if unresolved == [] do
        result
      else
        Map.put(result, "pagination_unresolved", unresolved)
      end
    end
  end

  @doc """
  Extract a single pagination entry from a `{containing_method, call_node}` tuple.

  Returns a map with `"target_method"` (string or nil for unresolved variable references),
  `"containing_method"`, `"strategy"`, and strategy-specific fields.
  """
  @spec extract_pagination_entry({String.t(), map()}) :: map()
  def extract_pagination_entry({containing_method, call_node}) do
    strategy_method = call_node.callee.property.name
    strategy = Map.fetch!(@strategy_methods, strategy_method)
    args = call_node.arguments

    # First argument is the target method name — string literal or variable reference
    target_method =
      case args do
        [%{type: "Literal", value: name} | _] when is_binary(name) -> name
        _ -> nil
      end

    strategy
    |> build_entry(args)
    |> Map.put("target_method", target_method)
    |> Map.put("containing_method", containing_method)
  end

  # --- AST Walking ---

  # Walk a MethodDefinition, returning {containing_method, call_node} tuples.
  # Threads the containing method name so each pagination call knows its provenance.
  defp walk_method_for_pagination(%{type: "MethodDefinition", key: %{name: name}} = method) do
    method
    |> walk_ast_for_calls()
    |> Enum.map(&{name, &1})
  end

  # Recursively walk an AST node tree to find pagination CallExpression nodes.
  # Walks list children in source order (preserving AST structure).
  defp walk_ast_for_calls(
         %{
           type: "CallExpression",
           callee: %{
             type: "MemberExpression",
             object: %{type: "ThisExpression"},
             property: %{type: "Identifier", name: name}
           }
         } = node
       ) do
    if Map.has_key?(@strategy_methods, name) do
      [node | walk_ast_children(node)]
    else
      walk_ast_children(node)
    end
  end

  defp walk_ast_for_calls(node) when is_map(node), do: walk_ast_children(node)
  defp walk_ast_for_calls(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &walk_ast_for_calls/1)
  defp walk_ast_for_calls(_), do: []

  # Walk child values of an AST node. Lists are walked in order (source-ordered).
  # Map values are walked in consistent order (Elixir atom key ordering).
  defp walk_ast_children(node) when is_map(node) do
    node
    |> Map.values()
    |> Enum.flat_map(&walk_ast_for_calls/1)
  end

  # --- Strategy-Specific Extraction ---

  # Build entry map based on strategy type and argument positions.
  # Args: [method, symbol, since, limit, ...strategy-specific]
  defp build_entry("dynamic", args) do
    %{
      "strategy" => "dynamic",
      "max_entries_per_request" => extract_literal_value(Enum.at(args, 5))
    }
  end

  defp build_entry("deterministic", args) do
    %{
      "strategy" => "deterministic",
      "max_entries_per_request" => extract_literal_value(Enum.at(args, 6))
    }
  end

  defp build_entry("cursor", args) do
    %{
      "strategy" => "cursor",
      "cursor_received" => extract_literal_value(Enum.at(args, 5)),
      "cursor_sent" => extract_literal_value(Enum.at(args, 6)),
      "cursor_increment" => extract_literal_value(Enum.at(args, 7)),
      "max_entries_per_request" => extract_literal_value(Enum.at(args, 8))
    }
  end

  defp build_entry("incremental", args) do
    %{
      "strategy" => "incremental",
      "page_key" => extract_literal_value(Enum.at(args, 5)),
      "max_entries_per_request" => extract_literal_value(Enum.at(args, 6))
    }
  end

  # Extract a literal value from an AST argument node.
  # OXC uses ESTree "Literal" nodes for strings, numbers, and booleans.
  # Returns nil for non-resolvable expressions (variables, complex expressions).
  defp extract_literal_value(%{type: "Literal", value: v}), do: v
  defp extract_literal_value(%{type: "Identifier", name: "undefined"}), do: nil
  defp extract_literal_value(_), do: nil

  # Split entries into resolved (target_method is a string) and unresolved (target_method is nil).
  defp split_resolved_unresolved(entries) do
    Enum.split_with(entries, fn entry -> entry["target_method"] != nil end)
  end

  # Group resolved entries by target method name. Each key maps to a list of entries,
  # preserving all variants (e.g. coinbase fetchAccounts V2 and V3 cursor configs).
  defp group_entries(entries) do
    Enum.group_by(entries, & &1["target_method"])
  end
end

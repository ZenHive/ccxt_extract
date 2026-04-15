defmodule CcxtExtract.UnifiedEndpoints do
  @moduledoc """
  Extract unified method → interface method mappings from CCXT exchange TypeScript files.

  CCXT unified methods (`fetchTicker`, `fetchBalance`, `createOrder`, etc.)
  internally call raw interface methods (`publicGetV5MarketTickers`,
  `privatePostV5OrderCreate`, etc.). This module walks each unified method's
  AST body, finds `this.<interfaceMethod>()` call expressions where the method
  name contains an HTTP verb (Get, Post, Put, Delete, Patch), and records the
  mapping.

  Multiple interface calls per unified method is common — exchanges branch
  by market type, account type, or API version.

  ## Usage

      {:ok, exchanges, stats} = CcxtExtract.UnifiedEndpoints.extract()
      CcxtExtract.UnifiedEndpoints.write!(exchanges)
  """

  use CcxtExtract.OXCExtractor, output_file: "unified_endpoints.json"

  # Path to the base Exchange class — super.* calls resolve here
  @base_exchange_path "base/Exchange.ts"

  # Prefixes that identify CCXT unified API methods
  @unified_prefixes ~w(fetch create cancel edit withdraw transfer set add reduce borrow repay close)

  # Suffixes that indicate internal helper methods, not unified API methods.
  # Short suffixes: createOrderRequest, fetchAccountHelper, fetchTransactionsHelper
  # Cache/supplement: fetchMarketsFromCache, fetchDepositAddressSupplement
  # Source-qualified: fetchMarketsFromAPI, fetchMarketsFromRest
  @helper_suffixes ~w(Request Helper Params FromCache FromAPI FromRest Supplement Default WithMethod)

  # Specific method names that are exchange-internal helpers, not unified API methods.
  # These escape pattern-based detection because their names look like unified methods.
  @known_non_unified MapSet.new(~w(
    fetchNonce
    fetchLatestBlockHeight
    fetchDydxAccount
    fetchHip3Markets
  ))

  # "Default" variant pattern: fetchDefaultMarkets, createDefaultOrder, etc.
  # These are internal fallback methods, not unified API.
  @default_variant_pattern ~r/^(fetch|create|cancel|edit|withdraw|transfer)Default[A-Z]/

  # Regex matching HTTP verb in PascalCase within a camelCase method name.
  # CCXT generates interface method names with the verb embedded:
  # publicGetV5MarketTickers, privatePostV5OrderCreate, etc.
  @http_verb_pattern ~r/(Get|Post|Put|Delete|Patch)/

  # Versioned internal dispatch methods — exchange-specific version wrappers, not unified API.
  # e.g., fetchTickerV1, fetchTickerV2, fetchTickerV3, fetchTicker2, fetchAccountsV2
  @version_suffix_pattern ~r/(V\d+|\d+)$/

  # CCXT unified setter methods — the only set* methods that are part of the unified API.
  # Everything else (setUserAbstraction, setAgentAbstraction, setRef, setContractLeverage)
  # is exchange-specific.
  @unified_setters MapSet.new(~w(setLeverage setMarginMode setPositionMode setMargin))

  # Prefixes that indicate helper function calls, not CCXT-generated interface methods.
  # e.g., isPostOnly, handlePostOnly — contain an HTTP verb but are not transport methods.
  @non_interface_prefixes ~w(is handle)

  @impl true
  def source_dir, do: CcxtExtract.Paths.ts_src()

  @doc """
  Override default extract/0 to pre-load base Exchange method index for super.* resolution.
  """
  def extract do
    with_base_method_index(fn -> super() end)
  end

  @doc """
  Override parse_file/1 to ensure base method index is available for super.* resolution
  when parsing a single file outside of extract/0 (e.g., spot-checking one exchange).
  """
  def parse_file(path) do
    with_base_method_index(fn -> super(path) end)
  end

  @impl true
  def extract_from_ast(ast, filename) do
    export = Enum.find(ast.body, &(&1.type == :export_default_declaration))

    if export && export.declaration && Map.get(export.declaration, :body) do
      class = export.declaration
      class_name = if class.id, do: class.id.name, else: Path.rootname(filename)
      id = class_name
      parent_class = get_in(class, [:superClass, :name])

      all_methods = Enum.filter(class.body.body, &(&1.type == :method_definition))
      method_index = Map.new(all_methods, fn m -> {m.key.name, m} end)

      endpoints_map =
        all_methods
        |> Enum.filter(&unified_method?/1)
        |> Map.new(&extract_method_endpoints(&1, method_index))
        |> Enum.reject(fn {_name, calls} -> calls == [] end)
        |> Map.new()

      total_mappings = endpoints_map |> Map.values() |> List.flatten() |> length()

      %{
        "id" => id,
        "class_name" => class_name,
        "parent_class" => parent_class,
        "file" => filename,
        "unified_endpoint_count" => total_mappings,
        "unified_endpoints" => endpoints_map
      }
    end
  end

  @impl true
  def write_stats(exchanges) do
    %{
      "with_unified_endpoints" => Enum.count(exchanges, fn e -> e["unified_endpoint_count"] > 0 end),
      "total_mappings" => Enum.sum(Enum.map(exchanges, & &1["unified_endpoint_count"]))
    }
  end

  # --- Unified Method Detection ---

  # A unified method starts with a known prefix, passes all exclusion checks,
  # and (for set* methods) is in the unified setter whitelist.
  defp unified_method?(%{type: :method_definition, key: %{name: name}}) do
    has_unified_prefix?(name) and not excluded_method?(name)
  end

  defp unified_method?(_), do: false

  defp has_unified_prefix?(name), do: Enum.any?(@unified_prefixes, &String.starts_with?(name, &1))

  # Reject helpers, versioned variants, default fallbacks, known non-unified, and exchange-specific setters
  defp excluded_method?(name) do
    MapSet.member?(@known_non_unified, name) or
      Enum.any?(@helper_suffixes, &String.ends_with?(name, &1)) or
      Regex.match?(@version_suffix_pattern, name) or
      Regex.match?(@default_variant_pattern, name) or
      (String.starts_with?(name, "set") and name not in @unified_setters)
  end

  # --- Interface Method Extraction ---

  # For a unified method, walk its body AST and collect interface method names.
  # Collects both direct interface calls AND delegates through helper methods,
  # since CCXT unified methods commonly use both paths (e.g., fetchBalance calls
  # privateGetBalance directly for one market type and delegates to loadBalance
  # for another). Also resolves super.*() calls through the base Exchange class.
  # Returns {method_name, sorted_unique_interface_method_names}.
  @max_delegation_depth 3

  defp extract_method_endpoints(%{key: %{name: name}} = method, method_index) do
    all_this_calls = collect_this_calls(method)
    super_call_names = collect_super_calls(method)

    {interface_calls, delegate_calls} =
      Enum.split_with(all_this_calls, &interface_method_call?/1)

    # super.*() calls resolve to parent method bodies, which contain this.* calls
    # that dispatch polymorphically back to the child class
    super_delegates = resolve_super_calls(super_call_names)

    delegated_calls =
      resolve_delegates(delegate_calls ++ super_delegates, method_index, MapSet.new(), @max_delegation_depth)

    all_calls = interface_calls ++ delegated_calls

    {name, all_calls |> Enum.uniq() |> Enum.sort()}
  end

  # Recursively follow delegation: look up each delegate method in the class
  # and collect their interface calls, up to max_depth hops. Tracks visited
  # methods to prevent infinite loops from mutual recursion.
  defp resolve_delegates(_delegate_names, _method_index, _visited, 0), do: []

  defp resolve_delegates(delegate_names, method_index, visited, depth) do
    Enum.flat_map(delegate_names, &resolve_one_delegate(&1, method_index, visited, depth))
  end

  # Resolve a single delegate — skip if visited, otherwise look up and recurse.
  defp resolve_one_delegate(name, method_index, visited, depth) do
    with false <- MapSet.member?(visited, name),
         %{} = delegate_method <- Map.get(method_index, name) do
      visited = MapSet.put(visited, name)
      calls = collect_this_calls(delegate_method)
      {interface, nested} = Enum.split_with(calls, &interface_method_call?/1)
      interface ++ resolve_delegates(nested, method_index, visited, depth - 1)
    else
      _ -> []
    end
  end

  # --- Interface Method Detection ---

  # A CCXT interface method name contains an HTTP verb (Get/Post/Put/Delete/Patch)
  # and does NOT start with helper prefixes like "is" or "handle".
  defp interface_method_call?(name) do
    Regex.match?(@http_verb_pattern, name) and
      not Enum.any?(@non_interface_prefixes, &String.starts_with?(name, &1))
  end

  # --- AST Walking ---

  # Collect all this.<name>() call targets from an AST subtree.
  defp collect_this_calls(
         %{
           type: :call_expression,
           callee: %{
             type: :member_expression,
             object: %{type: :this_expression},
             property: %{type: :identifier, name: name}
           }
         } = node
       ) do
    [name | collect_this_calls_children(node)]
  end

  defp collect_this_calls(node) when is_map(node), do: collect_this_calls_children(node)

  defp collect_this_calls(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &collect_this_calls/1)

  defp collect_this_calls(_), do: []

  defp collect_this_calls_children(node) when is_map(node) do
    node |> Map.values() |> Enum.flat_map(&collect_this_calls/1)
  end

  # --- Super Call Collection ---

  # Collect all super.<name>() call targets from an AST subtree.
  # Mirrors collect_this_calls but matches %{type: :super} instead of ThisExpression.
  defp collect_super_calls(
         %{
           type: :call_expression,
           callee: %{type: :member_expression, object: %{type: :super}, property: %{type: :identifier, name: name}}
         } = node
       ) do
    [name | collect_super_calls_children(node)]
  end

  defp collect_super_calls(node) when is_map(node), do: collect_super_calls_children(node)

  defp collect_super_calls(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &collect_super_calls/1)

  defp collect_super_calls(_), do: []

  defp collect_super_calls_children(node) when is_map(node) do
    node |> Map.values() |> Enum.flat_map(&collect_super_calls/1)
  end

  # --- Super Call Resolution ---

  # For each super.method() call, look up the parent method in the base Exchange
  # class and walk it for this.* calls. Those calls resolve polymorphically to the
  # child class's methods, so they become delegate names for the child's method_index.
  defp resolve_super_calls(super_call_names) do
    base_index = Process.get(:base_method_index, %{})

    Enum.flat_map(super_call_names, fn name ->
      case Map.get(base_index, name) do
        nil -> []
        method -> collect_this_calls(method)
      end
    end)
  end

  # --- Base Exchange Method Index ---

  # Load base Exchange method index, run the callback, then clean up.
  # Idempotent: if the index is already loaded (e.g., parse_file called from extract),
  # skips re-parsing and does not clean up the outer caller's index.
  defp with_base_method_index(fun) do
    already_loaded = Process.get(:base_method_index) != nil
    if !already_loaded, do: load_base_method_index()

    try do
      fun.()
    after
      if !already_loaded, do: Process.delete(:base_method_index)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp load_base_method_index do
    path = Path.join(source_dir(), @base_exchange_path)

    with {:ok, source} <- File.read(path),
         {:ok, ast} <- OXC.parse(source, "Exchange.ts"),
         %{} = index <- build_method_index_from_ast(ast) do
      Process.put(:base_method_index, index)
    else
      {:error, reason} ->
        Logger.warning("Base Exchange.ts unavailable (#{inspect(reason)}) — super.* resolution disabled")

      nil ->
        :ok
    end
  end

  # Extract a method_name → method_ast_node map from a class AST
  defp build_method_index_from_ast(ast) do
    export = Enum.find(ast.body, &(&1.type == :export_default_declaration))

    if export && export.declaration && Map.get(export.declaration, :body) do
      export.declaration.body.body
      |> Enum.filter(&(&1.type == :method_definition))
      |> Map.new(fn m -> {m.key.name, m} end)
    end
  end
end

defmodule CcxtExtract.Summary do
  @moduledoc """
  Combine exchange metadata and class hierarchy into summary statistics.

  Reads the JSON outputs from `CcxtExtract.Exchanges` (Task 2a) and
  `CcxtExtract.Classes` (Task 2b), computes aggregate counts, and builds
  family groupings that distinguish variants from aliases that inherit through
  the class hierarchy.

  ## Usage

      {:ok, summary} = CcxtExtract.Summary.extract()
      CcxtExtract.Summary.write!(summary)
  """

  @exchanges_file "exchanges.json"
  @classes_file "class_hierarchy.json"
  @output_file "exchange_summary.json"

  @doc """
  Read discovery files and compute exchange summary statistics.

  Accepts an optional `scope` (from `CcxtExtract.TaskScope.parse_and_resolve!/3`).
  When scope is a `MapSet` of exchange IDs, `exchanges` and `classes` are
  filtered to the in-scope set before reducing. The inheritance `tree` and
  `ws_counterparts` always reflect the full CCXT source — `classes.ex`
  precedent (Task 5 Q2): the hierarchy is load-bearing for family inheritance
  and must stay universe-wide. `find_root_ancestor/2` walks the full tree so
  in-scope classes still resolve to their real roots, and `has_ws` lookups
  against `ws_counterparts` remain honest when scope narrows to a variant
  whose WS counterpart lives outside the scope.

  Returns `{:ok, summary}` or `{:error, {:missing_input, path}}` if
  a required input file does not exist.
  """
  @spec extract(:all | MapSet.t(String.t())) ::
          {:ok, map()} | {:error, {:missing_input, String.t()}}
  def extract(scope \\ :all) do
    discoveries = CcxtExtract.Paths.discoveries()
    exchanges_path = Path.join(discoveries, @exchanges_file)
    classes_path = Path.join(discoveries, @classes_file)

    with {:ok, exchanges_data} <- read_json(exchanges_path),
         {:ok, classes_data} <- read_json(classes_path) do
      exchanges =
        CcxtExtract.TaskScope.filter_entries(exchanges_data["exchanges"], scope, "id")

      classes =
        CcxtExtract.TaskScope.filter_entries(classes_data["classes"], scope, "id")

      tree = classes_data["tree"]
      ws_counterparts = classes_data["ws_counterparts"]

      summary = build_summary(exchanges, classes, tree, ws_counterparts)
      {:ok, summary}
    end
  end

  @doc """
  Write summary to `priv/discoveries/exchange_summary.json`.

  Accepts `:tier_scope` option — the JSON-serialisable value from
  `CcxtExtract.TaskScope.parse_and_resolve!/3` that records the active scope
  in the output envelope.
  """
  @spec write!(map(), keyword()) :: :ok
  def write!(summary, opts \\ []) do
    output_path =
      Keyword.get(opts, :output_path, CcxtExtract.Paths.priv(Path.join("discoveries", @output_file)))

    tier_scope = Keyword.get(opts, :tier_scope, "all")
    stamped = Map.put(summary, "tier_scope", tier_scope)

    File.mkdir_p!(Path.dirname(output_path))

    json = Jason.encode!(stamped, pretty: true)
    File.write!(output_path, json)
    :ok
  end

  @doc """
  Build full summary from exchanges, classes, tree, and WS counterparts.
  """
  @spec build_summary([map()], [map()], map(), [String.t()]) :: map()
  def build_summary(exchanges, classes, tree, ws_counterparts) do
    ws_set = MapSet.new(ws_counterparts)
    families = build_families(exchanges, classes, tree, ws_set)
    orphans = find_orphan_aliases(exchanges, classes)

    alias_count = Enum.count(exchanges, & &1["alias"])
    rest_count = Enum.count(classes, &(&1["type"] == "rest"))
    ws_count = Enum.count(classes, &(&1["type"] == "ws"))

    %{
      "extracted_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "source_files" => %{
        "exchanges" => @exchanges_file,
        "class_hierarchy" => @classes_file
      },
      "counts" => %{
        "exchanges" => %{
          "total" => length(exchanges),
          "real" => length(exchanges) - alias_count,
          "aliases" => alias_count
        },
        "classes" => %{
          "total" => length(classes),
          "rest" => rest_count,
          "ws" => ws_count
        },
        "families" => length(families),
        "exchanges_with_ws" => length(ws_counterparts),
        "orphan_aliases" => length(orphans)
      },
      "families" => families,
      "orphan_aliases" => orphans
    }
  end

  @doc """
  Build family groupings from exchanges, classes, and inheritance tree.

  Groups REST classes by their root ancestor (the class just below "Exchange"
  in the inheritance chain). Each family member is classified as either a
  variant (has its own class, not an alias) or an alias (alias=true in
  exchange metadata).

  Aliases that have their own class entry are attached to the parent family in
  the `"aliases"` list. Aliases with no corresponding class entry are
  collected separately via `find_orphan_aliases/2`.
  """
  @spec build_families([map()], [map()], map(), MapSet.t()) :: [map()]
  def build_families(exchanges, classes, tree, ws_set) do
    inverted = invert_tree(tree)

    # Build alias lookup from exchange metadata. Some aliases also have their
    # own class entry and will be attached to their resolved parent family.
    alias_set = exchanges |> Enum.filter(& &1["alias"]) |> MapSet.new(& &1["id"])

    # Group REST classes by their root ancestor
    rest_classes = Enum.filter(classes, &(&1["type"] == "rest"))

    family_groups =
      Enum.group_by(rest_classes, fn class ->
        find_root_ancestor(class["node_key"], inverted)
      end)

    # Build family entries
    family_groups
    |> Enum.map(fn {root_key, members} ->
      root_id = strip_type_prefix(root_key)

      # Member IDs excluding the root itself
      member_ids =
        members
        |> Enum.map(& &1["id"])
        |> Enum.reject(&(&1 == root_id))

      # Variants: non-alias members with their own class
      variants =
        member_ids
        |> Enum.reject(&MapSet.member?(alias_set, &1))
        |> Enum.sort()

      # Aliases: exchanges marked alias=true that have a class in this family
      family_aliases =
        member_ids
        |> Enum.filter(&MapSet.member?(alias_set, &1))
        |> Enum.sort()

      %{
        "root" => root_id,
        "variants" => variants,
        "aliases" => family_aliases,
        "variant_count" => length(variants),
        "alias_count" => length(family_aliases),
        "total_members" => 1 + length(variants) + length(family_aliases),
        "has_ws" => MapSet.member?(ws_set, root_id)
      }
    end)
    |> Enum.sort_by(& &1["root"])
  end

  @doc """
  Invert a tree from `%{parent => [children]}` to `%{child => parent}`.

      invert_tree(%{"Exchange" => ["rest:binance"], "rest:binance" => ["rest:binanceus"]})
      #=> %{"rest:binance" => "Exchange", "rest:binanceus" => "rest:binance"}
  """
  @spec invert_tree(map()) :: map()
  def invert_tree(tree) do
    Enum.reduce(tree, %{}, fn {parent, children}, acc ->
      Enum.reduce(children, acc, fn child, inner_acc ->
        Map.put(inner_acc, child, parent)
      end)
    end)
  end

  @doc """
  Walk up the inverted tree to find the root ancestor (child of "Exchange").

  Returns the node_key of the root ancestor. If the node's parent is
  "Exchange" (or not in the tree), returns the node itself.

      find_root_ancestor("rest:binanceus", %{
        "rest:binanceus" => "rest:binance",
        "rest:binance" => "Exchange"
      })
      #=> "rest:binance"
  """
  @spec find_root_ancestor(String.t(), map()) :: String.t()
  def find_root_ancestor(node_key, inverted) do
    case Map.get(inverted, node_key) do
      nil -> node_key
      "Exchange" -> node_key
      parent -> find_root_ancestor(parent, inverted)
    end
  end

  # Strip "rest:" or "ws:" prefix from a node_key to get the exchange ID
  defp strip_type_prefix(node_key) do
    case String.split(node_key, ":", parts: 2) do
      [_type, id] -> id
      [id] -> id
    end
  end

  @doc """
  Find alias exchanges that have no class entry in the hierarchy.

  These aliases cannot be attached to a family because the class hierarchy has
  no corresponding node for that exchange ID.

      find_orphan_aliases(exchanges, classes)
      #=> ["some_alias_without_a_class"]
  """
  @spec find_orphan_aliases([map()], [map()]) :: [String.t()]
  def find_orphan_aliases(exchanges, classes) do
    class_ids = MapSet.new(classes, & &1["id"])

    exchanges
    |> Enum.filter(fn ex -> ex["alias"] && !MapSet.member?(class_ids, ex["id"]) end)
    |> Enum.map(& &1["id"])
    |> Enum.sort()
  end

  # Read and decode a JSON file, returning {:error, {:missing_input, path}} if missing
  defp read_json(path) do
    if File.exists?(path) do
      {:ok, path |> File.read!() |> Jason.decode!()}
    else
      {:error, {:missing_input, path}}
    end
  end
end

defmodule CcxtExtract.ErrorClassHierarchy do
  @moduledoc """
  Extract CCXT's exception class inheritance tree from
  `priv/ccxt/ts/src/base/errorHierarchy.ts`.

  ## Why

  CCXT defines a single, shared exception class taxonomy in
  `errorHierarchy.ts` — a literal nested-object declaration mapping every
  thrown exception class to its parent (`BaseError → ExchangeError →
  AuthenticationError → PermissionDenied → AccountNotEnabled`, etc.).
  Consumers building a retry classifier, a status-code mapper, or any
  generic "is this exception transient?" check need the full ancestor
  chain of every class — not just the leaf class name. Extracting the
  tree once into a structured artifact lets every consumer answer "is
  `RateLimitExceeded` a descendant of `NetworkError`?" without reparsing
  CCXT source.

  The hierarchy is corpus-level: same data for every exchange. The
  pipeline copies the result into each per-exchange JSON so consumers
  read one canonical shape per exchange (matching the existing
  `error_code_fields` / `throw_dispatches` / `handle_errors` co-location).

  ## Output Structure

  Returns a map with three keys (never `nil`):

      %{
        "tree" => %{"BaseError" => %{"ExchangeError" => %{...}, "OperationFailed" => %{...}, ...}},
        "flat_parents" => %{"AccountNotEnabled" => "PermissionDenied",
                            "PermissionDenied" => "AuthenticationError",
                            ...,
                            "BaseError" => nil},
        "ancestors" => %{"AccountNotEnabled" => ["PermissionDenied", "AuthenticationError",
                                                  "ExchangeError", "BaseError"],
                          ...,
                          "BaseError" => []}
      }

  * `tree` — literal mirror of `errorHierarchy.ts`. Recursive: each value
    is a (possibly-empty) map of children.
  * `flat_parents` — `class_name => parent_name` (root maps to `nil`).
    O(1) parent lookup.
  * `ancestors` — `class_name => [parent, grandparent, ..., BaseError]`.
    Empty list for the root. Pre-computed so consumers don't recurse.

  ## Honesty Rule

  No guesses. The source file is a literal object declaration; if OXC
  can't resolve the export's `ObjectExpression` (file moved, refactored
  to dynamic construction, etc.) `extract/0` returns
  `{:error, reason}` rather than emitting a partial tree. The mix task
  raises in that case.
  """

  @output_file "error_class_hierarchy.json"
  @source_path Path.join(["base", "errorHierarchy.ts"])

  @doc """
  Extract the error class hierarchy from CCXT TypeScript source.

  Reads `priv/ccxt/ts/src/base/errorHierarchy.ts`, parses with OXC,
  resolves the default export to its declaring `ObjectExpression`, and
  walks the literal nested object into the three-shape result map.

  Returns `{:ok, %{"tree" => ..., "flat_parents" => ..., "ancestors" => ...}}`
  or `{:error, reason}` when the source file is missing or the AST does
  not match the expected literal-object shape.
  """
  @spec extract() :: {:ok, map()} | {:error, term()}
  def extract do
    path = Path.join(CcxtExtract.Paths.ts_src(), @source_path)

    with {:ok, source} <- read_source(path),
         {:ok, ast} <- OXC.parse(source, @source_path) do
      from_ast(ast)
    end
  end

  @doc """
  Build the hierarchy record from a parsed OXC AST.

  Public seam for tests — callers that already have a parsed AST (e.g.
  unit tests with synthetic ObjectExpressions) skip the file read + OXC
  parse and feed the AST directly.
  """
  @spec from_ast(map()) :: {:ok, map()} | {:error, term()}
  def from_ast(ast) do
    case find_default_export_object(ast) do
      {:ok, object_expr} -> {:ok, build_record(walk_object(object_expr))}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Write the extracted hierarchy to
  `priv/discoveries/error_class_hierarchy.json`.

  Unlike per-exchange aggregates, this is a singleton record (one tree
  for all of CCXT). Tier scope is stamped for traceability but does not
  filter the tree — same rationale as `Classes.write!/2`.

  Options:

    * `:output_path` — override the default discovery JSON path.
    * `:tier_scope` — value from `Scope.to_manifest_value/1`. Defaults
      to `"all"`.
    * `:extracted_at` — override the ISO 8601 timestamp.
  """
  @spec write!(map(), keyword()) :: :ok
  def write!(record, opts \\ []) when is_map(record) do
    output_path =
      Keyword.get(
        opts,
        :output_path,
        CcxtExtract.Paths.out(Path.join("discoveries", @output_file))
      )

    extracted_at =
      Keyword.get_lazy(opts, :extracted_at, fn ->
        CcxtExtract.Clock.timestamp(:extracted_at)
      end)

    envelope =
      Map.merge(record, %{
        "extracted_at" => extracted_at,
        "tier_scope" => Keyword.get(opts, :tier_scope, "all"),
        "class_count" => map_size(record["flat_parents"])
      })

    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, Jason.encode!(CcxtExtract.AstNormalize.to_encodable(envelope), pretty: true))
    :ok
  end

  @doc """
  The set of required keys in an `error_class_hierarchy` record. Exposed
  for the contract invariant.
  """
  @spec required_keys() :: [String.t()]
  def required_keys, do: ["tree", "flat_parents", "ancestors"]

  # --- AST resolution ---

  defp read_source(path) do
    case File.read(path) do
      {:ok, source} -> {:ok, source}
      {:error, reason} -> {:error, {:source_unreadable, path, reason}}
    end
  end

  # The file shape is `const errorHierarchy = {...}; export default errorHierarchy;`.
  # OXC parses the export as `:export_default_declaration` whose
  # `.declaration` is an `:identifier`. Resolve back to the matching
  # `:variable_declaration` to get the `ObjectExpression`. Also handle a
  # future refactor where the literal is exported directly.
  defp find_default_export_object(%{body: body}) do
    export = Enum.find(body, &(&1.type == :export_default_declaration))

    case export do
      nil ->
        {:error, :no_default_export}

      %{declaration: %{type: :object_expression} = obj} ->
        {:ok, obj}

      %{declaration: %{type: :identifier, name: name}} ->
        resolve_identifier_to_object(body, name)

      _other ->
        {:error, :unexpected_default_export_shape}
    end
  end

  defp resolve_identifier_to_object(body, name) do
    body
    |> Enum.flat_map(fn
      %{type: :variable_declaration, declarations: decls} -> decls
      _ -> []
    end)
    |> Enum.find_value({:error, {:identifier_not_found, name}}, fn decl ->
      case decl do
        %{
          id: %{type: :identifier, name: ^name},
          init: %{type: :object_expression} = obj
        } ->
          {:ok, obj}

        _ ->
          nil
      end
    end)
  end

  # --- Tree builder ---

  # Walk an OXC ObjectExpression into a nested Elixir map. Keys come from
  # property `.key.value` (literal) or `.key.name` (identifier shorthand,
  # e.g. `{ Foo: {} }`). Values are recursively walked ObjectExpressions.
  # Anything else is honestly skipped — `errorHierarchy.ts` is a literal
  # tree and nothing else is expected.
  defp walk_object(%{type: :object_expression, properties: props}) do
    props
    |> Enum.map(fn prop -> {property_key(prop.key), walk_object(prop.value)} end)
    |> Enum.reject(fn {key, _child} -> is_nil(key) end)
    |> Map.new()
  end

  defp walk_object(_other), do: %{}

  defp property_key(%{type: :literal, value: value}) when is_binary(value), do: value
  defp property_key(%{type: :identifier, name: name}), do: name
  defp property_key(_other), do: nil

  # --- Record builder ---

  defp build_record(tree) do
    flat_parents = build_flat_parents(tree)
    ancestors = build_ancestors(flat_parents)

    %{
      "tree" => tree,
      "flat_parents" => flat_parents,
      "ancestors" => ancestors
    }
  end

  # Walk the tree depth-first; every key gets the immediately-enclosing
  # parent (or `nil` for roots). The root level — keys directly under the
  # tree root — has no enclosing parent in the tree so they map to `nil`.
  defp build_flat_parents(tree) do
    Enum.reduce(tree, %{}, fn {class_name, children}, acc ->
      acc
      |> Map.put(class_name, nil)
      |> walk_for_parents(children, class_name)
    end)
  end

  defp walk_for_parents(acc, children, parent) when is_map(children) do
    Enum.reduce(children, acc, fn {class_name, grandchildren}, inner_acc ->
      inner_acc
      |> Map.put(class_name, parent)
      |> walk_for_parents(grandchildren, class_name)
    end)
  end

  # Pre-compute every class's ancestor chain by walking flat_parents.
  defp build_ancestors(flat_parents) do
    Map.new(flat_parents, fn {class_name, _parent} ->
      {class_name, ancestors_of(class_name, flat_parents)}
    end)
  end

  defp ancestors_of(class_name, flat_parents) do
    ancestors_of(class_name, flat_parents, MapSet.new([class_name]))
  end

  defp ancestors_of(class_name, flat_parents, visited) do
    case Map.get(flat_parents, class_name) do
      nil ->
        []

      parent ->
        if MapSet.member?(visited, parent) do
          []
        else
          [parent | ancestors_of(parent, flat_parents, MapSet.put(visited, parent))]
        end
    end
  end
end

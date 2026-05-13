defmodule CcxtExtract.Normalization.Balance do
  @moduledoc """
  Derive `field_maps["balance"]` from a per-exchange `parse_methods.json` entry.

  Scope (Task 77): handles exchanges whose `parseBalance` body ends with
  `return this.safeBalance(result)`, where `result` is an Identifier (the
  built-up balance map). The per-currency fields (`free`, `used`, `total`,
  `debt`) are assigned imperatively via `account['free'] = this.safe*(...)`;
  there is no ObjectExpression argument to `safeBalance` — every corpus
  exchange (all 80 with a `parseBalance` override) passes a variable.

  ## Pattern

  CCXT's `parseBalance` imperative shape:

      const account = this.account();
      account['free']  = this.safeString(balance, 'freeKey');
      account['used']  = this.safeString(balance, 'usedKey');
      account['total'] = this.safeString(balance, 'totalKey');
      result[code] = account;
      return this.safeBalance(result);

  The module walks all top-level and loop-nested `ExpressionStatement`
  assignment nodes, collecting `account['<field>'] = this.safe*(balance, 'key')`
  entries. Only string-literal Literal wire keys are slottable; Identifier
  or computed keys produce `nil` for that slot.

  ## Output

      %{
        "field_map" => %{
          "free"    => slot() | nil,
          "used"    => slot() | nil,
          "total"   => slot() | nil,
          "debt"    => slot() | nil,
          "info"    => nil,          # structurally null (raw pass-through)
          "timestamp" => slot() | nil,
          "datetime"  => nil         # structurally null (iso8601 derived)
        },
        "extras" => [],
        "_unresolved_reason" => nil | String.t()
      }

  Each `slot()` is `%{"key" => String.t(), "coercion" => method, "format" => "ms" | "s" | nil}`.
  Method is drawn from the closed vocabulary `[safeString, safeString2, safeStringN,
  safeNumber, safeNumber2, safeInteger, safeInteger2, safeTimestamp]`.

  `debt` rarely appears in corpus exchanges; its slot is `nil` when not found.

  ## `_unresolved_reason` vocabulary

  - `nil` — `safeBalance(Identifier)` pattern found; per-field slots may still be nil
  - `"non_safe_balance_return:<callee>"` — return calls a different method
  - `"no_return_statement"` — body has no `ReturnStatement` at all
  - `"identifier_return"` — return is a bare Identifier (pre-built variable,
    not a `safeBalance(...)` wrapper call; e.g. lbank's `return result`)
  - `"unrecognized_return_shape"` — body has a `ReturnStatement` whose
    argument is none of the shapes above (e.g. `return foo() + bar()`,
    `return {...}`, etc.)

  ## Three-Strikes Patch counter

  # Patch count: 0/3
  """

  alias CcxtExtract.SignRecipe.ASTHelpers

  @unified_fields ~w(info timestamp datetime free used total debt)

  @safe_str ~w(safeString safeString2 safeStringN)
  @safe_num ~w(safeNumber safeNumber2)
  @safe_int ~w(safeInteger safeInteger2)
  @safe_ts ~w(safeTimestamp)
  @slot_vocab @safe_str ++ @safe_num ++ @safe_int ++ @safe_ts

  @structurally_null ~w(info datetime)
  @per_currency_fields ~w(free used total debt)

  @doc """
  Derive the balance field map from a `parse_methods.json` entry for one exchange.

  Returns `nil` when there is no `parseBalance` override. Returns a map with
  a non-nil `_unresolved_reason` when the return structure is not the slottable
  `safeBalance(Identifier)` pattern.
  """
  @spec derive(map() | nil) :: map() | nil
  def derive(nil), do: nil

  def derive(parse_methods_entry) when is_map(parse_methods_entry) do
    case get_in(parse_methods_entry, ["parse_methods", "parseBalance"]) do
      ast when is_map(ast) -> derive_from_ast(ast)
      _ -> nil
    end
  end

  def derive(_), do: nil

  @doc "Returns the list of 7 unified balance field names."
  @spec unified_fields() :: [String.t()]
  def unified_fields, do: @unified_fields

  # ---------------------------------------------------------------------------
  # Internal derivation
  # ---------------------------------------------------------------------------

  @spec derive_from_ast(map()) :: map()
  defp derive_from_ast(ast) do
    body_stmts = get_in(ast, ["body", "body"]) || []

    case find_safe_balance_return(body_stmts) do
      {:ok, :identifier_arg} -> build_result(body_stmts)
      {:error, reason} -> unresolved(reason)
    end
  end

  # Scans for the last ReturnStatement whose argument is `this.safeBalance(<Identifier>)`.
  @spec find_safe_balance_return([map()]) :: {:ok, :identifier_arg} | {:error, String.t()}
  defp find_safe_balance_return(body_stmts) do
    last_return =
      body_stmts
      |> Enum.filter(&match?(%{"type" => "ReturnStatement"}, &1))
      |> List.last()

    case last_return do
      nil ->
        {:error, "no_return_statement"}

      %{
        "argument" => %{
          "type" => "CallExpression",
          "callee" => %{
            "type" => "MemberExpression",
            "object" => %{"type" => "ThisExpression"},
            "property" => %{"type" => "Identifier", "name" => "safeBalance"}
          },
          "arguments" => [%{"type" => "Identifier"} | _]
        }
      } ->
        {:ok, :identifier_arg}

      %{
        "argument" => %{
          "type" => "CallExpression",
          "callee" => %{
            "type" => "MemberExpression",
            "object" => %{"type" => "ThisExpression"},
            "property" => %{"type" => "Identifier", "name" => callee_name}
          }
        }
      } ->
        {:error, "non_safe_balance_return:#{callee_name}"}

      # `return someIdentifier;` — a pre-built balance map returned bare,
      # not wrapped in a `safeBalance(...)` call. Seen on lbank.
      %{"argument" => %{"type" => "Identifier"}} ->
        {:error, "identifier_return"}

      _ ->
        {:error, "unrecognized_return_shape"}
    end
  end

  # Walk all top-level and loop-nested statements to collect imperative
  # per-currency field assignments, then build the field_map.
  @spec build_result([map()]) :: map()
  defp build_result(body_stmts) do
    # Collect top-level bindings for timestamp derivation.
    bindings = ASTHelpers.collect_bindings(body_stmts)

    # Collect per-currency assignments from all statement levels.
    assignments = collect_field_assignments(body_stmts)

    field_map =
      Map.new(@unified_fields, fn field ->
        {field, classify_field(field, assignments, bindings)}
      end)

    %{"field_map" => field_map, "extras" => [], "_unresolved_reason" => nil}
  end

  # Walk top-level and one level of loop/if bodies for imperative assignments.
  # Pattern: account['free'] = this.safeString(balance, 'key')
  @spec collect_field_assignments([map()]) :: %{String.t() => map()}
  defp collect_field_assignments(stmts) do
    stmts
    |> Enum.flat_map(&extract_assignments_from_stmt/1)
    |> Map.new()
  end

  @spec extract_assignments_from_stmt(map()) :: [{String.t(), map()}]
  defp extract_assignments_from_stmt(%{"type" => "ExpressionStatement", "expression" => expr}) do
    extract_balance_assignment(expr)
  end

  # Recurse into ForStatement / ForInStatement / ForOfStatement / IfStatement bodies.
  defp extract_assignments_from_stmt(%{"type" => type, "body" => body})
       when type in ~w(ForStatement ForInStatement ForOfStatement WhileStatement) do
    inner_stmts =
      case body do
        %{"type" => "BlockStatement", "body" => inner} when is_list(inner) -> inner
        s when is_map(s) -> [s]
        _ -> []
      end

    Enum.flat_map(inner_stmts, &extract_assignments_from_stmt/1)
  end

  defp extract_assignments_from_stmt(%{"type" => "IfStatement"} = stmt) do
    consequent_stmts =
      case stmt["consequent"] do
        %{"type" => "BlockStatement", "body" => inner} -> inner
        s when is_map(s) -> [s]
        _ -> []
      end

    alternate_stmts =
      case stmt["alternate"] do
        %{"type" => "BlockStatement", "body" => inner} -> inner
        s when is_map(s) -> [s]
        nil -> []
        _ -> []
      end

    Enum.flat_map(consequent_stmts ++ alternate_stmts, &extract_assignments_from_stmt/1)
  end

  defp extract_assignments_from_stmt(_), do: []

  # Extract a balance-field assignment: `account['free'] = this.safe*(balance, 'key')`
  # Requires the LHS object to be the `account` Identifier — otherwise unrelated
  # MemberExpressions like `balance['free'] = X` would be mis-classified.
  @spec extract_balance_assignment(map()) :: [{String.t(), map()}]
  defp extract_balance_assignment(%{
         "type" => "AssignmentExpression",
         "left" => %{
           "type" => "MemberExpression",
           "computed" => true,
           "object" => %{"type" => "Identifier", "name" => "account"},
           "property" => %{"type" => "Literal", "value" => field_name}
         },
         "right" => right
       })
       when is_binary(field_name) and field_name in @per_currency_fields do
    [{field_name, right}]
  end

  defp extract_balance_assignment(_), do: []

  # ---------------------------------------------------------------------------
  # Per-field classification
  # ---------------------------------------------------------------------------

  @spec classify_field(String.t(), %{String.t() => map()}, [{String.t(), map()}]) :: map() | nil
  defp classify_field(field, _assignments, _bindings) when field in @structurally_null, do: nil

  defp classify_field("timestamp", _assignments, bindings) do
    classify_timestamp_from_bindings(bindings)
  end

  defp classify_field(field, assignments, _bindings) when field in @per_currency_fields do
    case Map.get(assignments, field) do
      nil -> nil
      value_node -> classify_generic(value_node)
    end
  end

  # --- timestamp: scan top-level bindings for `const timestamp = this.safe*(...)` ---

  @spec classify_timestamp_from_bindings([{String.t(), map()}]) :: map() | nil
  defp classify_timestamp_from_bindings(bindings) do
    case lookup_binding("timestamp", bindings) do
      nil ->
        nil

      init ->
        case classify_safe_call(init) do
          {:ok, %{method: method, idx_arg: idx_arg}} when method in @safe_int ->
            build_slot(idx_arg, method, "ms")

          {:ok, %{method: method, idx_arg: idx_arg}} when method in @safe_ts ->
            build_slot(idx_arg, method, "s")

          _ ->
            nil
        end
    end
  end

  # --- per-currency slot ---

  @spec classify_generic(map()) :: map() | nil
  defp classify_generic(value_node) do
    case classify_safe_call(value_node) do
      {:ok, %{method: method, idx_arg: idx_arg}} when method in @slot_vocab ->
        build_slot(idx_arg, method, nil)

      _ ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  @spec classify_safe_call(term()) :: {:ok, %{method: String.t(), idx_arg: map()}} | :error
  defp classify_safe_call(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => method}
         },
         "arguments" => [_obj, idx_arg | _rest]
       }) do
    {:ok, %{method: method, idx_arg: idx_arg}}
  end

  defp classify_safe_call(_), do: :error

  @spec build_slot(map(), String.t(), String.t() | nil) :: map() | nil
  defp build_slot(%{"type" => "Literal", "value" => key}, method, format) when is_binary(key) do
    %{"key" => key, "coercion" => method, "format" => format}
  end

  defp build_slot(_, _, _), do: nil

  @spec lookup_binding(String.t(), [{String.t(), map()}]) :: map() | nil
  defp lookup_binding(name, bindings) do
    Enum.find_value(bindings, fn
      {^name, init} when is_map(init) -> init
      _ -> nil
    end)
  end

  @spec unresolved(String.t()) :: map()
  defp unresolved(reason) do
    null_field_map = Map.new(@unified_fields, fn field -> {field, nil} end)
    %{"field_map" => null_field_map, "extras" => [], "_unresolved_reason" => reason}
  end
end

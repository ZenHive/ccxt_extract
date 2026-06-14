defmodule CcxtExtract.HandleErrors do
  @moduledoc """
  Extract the `handleErrors()` method body as raw ESTree AST for every REST exchange.

  The `handleErrors()` method defines how each exchange maps HTTP responses and
  error codes to CCXT exception types. This module extracts the complete method AST
  alongside the `exceptions` and `httpExceptions` from each exchange's `describe()`.

  Together, the AST (conditional logic, fallthrough, edge cases) and the describe
  exceptions (static lookup tables) give consumers the full error-handling picture.

  Reuses parameter and type extraction from `CcxtExtract.Methods`.

  ## Usage

      {:ok, exchanges, stats} = CcxtExtract.HandleErrors.extract()
      CcxtExtract.HandleErrors.write!(exchanges)
  """

  use CcxtExtract.OXCExtractor, output_file: "handle_errors.json"

  alias CcxtExtract.ErrorDispatch
  alias CcxtExtract.ErrorHierarchy
  alias CcxtExtract.JsonIO

  @impl true
  def source_dir, do: CcxtExtract.Paths.ts_src()

  @impl true
  def extract_from_ast(ast, filename) do
    export = Enum.find(ast.body, &(&1.type == :export_default_declaration))

    if export && export.declaration && Map.get(export.declaration, :body) do
      class = export.declaration
      class_name = if class.id, do: class.id.name
      id = class_name || Path.rootname(filename)

      handle_errors_data =
        class.body.body
        |> find_handle_errors_method()
        |> CcxtExtract.MethodAST.extract()

      {exceptions, http_exceptions} = load_describe_exceptions(id)

      %{
        "id" => id,
        "class_name" => class_name,
        "file" => filename,
        "handle_errors" => handle_errors_data,
        "exceptions" => exceptions,
        "http_exceptions" => http_exceptions
      }
    end
  end

  @impl true
  def write_stats(exchanges) do
    %{"with_handle_errors" => Enum.count(exchanges, & &1["handle_errors"])}
  end

  @doc """
  Find the handleErrors() MethodDefinition in a class body.

  Returns the AST node or nil if not found.
  """
  @spec find_handle_errors_method([map()]) :: map() | nil
  def find_handle_errors_method(class_body) do
    Enum.find(class_body, fn member ->
      member.type == :method_definition && member.key.name == "handleErrors"
    end)
  end

  @doc """
  Load exceptions and httpExceptions from an exchange's describe() JSON.

  Returns `{exceptions, http_exceptions}` where each is a map or nil.
  Returns `{nil, nil}` if the describe file doesn't exist.
  """
  @spec load_describe_exceptions(String.t()) :: {map() | nil, map() | nil}
  # sobelow_skip ["Traversal.FileModule"]
  def load_describe_exceptions(exchange_id) do
    describe_path =
      CcxtExtract.Paths.priv(Path.join(["discoveries", "describe", "#{exchange_id}.json"]))

    if File.exists?(describe_path) do
      data = JsonIO.read_json!(describe_path)
      describe = data["describe"] || %{}

      {
        describe["exceptions"] |> normalize_map() |> strip_function_sentinels(),
        describe["httpExceptions"] |> normalize_map() |> strip_function_sentinels()
      }
    else
      {nil, nil}
    end
  end

  # Normalize non-map values (e.g. "__undefined" sentinel from QuickBEAM) to nil
  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_), do: nil

  # QuickBEAM serializes JS class references in describe() maps as
  # `"__function:ClassName"`. Defined once here so both call paths
  # (`strip_function_sentinel_value/1` directly below and
  # `normalize_class_name/1` further down) read from one constant.
  @function_sentinel "__function:"

  # CCXT's `httpExceptions` (and some `exceptions` entries) declare
  # values as JS class-constructor references — bare identifiers like
  # `ExchangeError` rather than the string `"ExchangeError"`. QuickBEAM
  # serializes those as `"__function:<ClassName>"`. The flat-parents
  # lookup in `error_classes_covered_by_hierarchy` is a bare-string key
  # match, so the sentinel can't resolve. Strip at the extraction
  # boundary so the emitted JSON carries bare class names and downstream
  # consumers (contract test, http_status_map, retryable_buckets) all
  # agree. Reuses `@function_sentinel` (defined below for
  # `normalize_class_name/1`) so the sentinel literal lives in exactly
  # one place — any future change to QuickBEAM's function-sentinel
  # encoding propagates through one constant. Double-prefix values like
  # `"__function:__function:Foo"` strip exactly once by design — the
  # empty-suffix test pins this; the sentinel never composes in CCXT's
  # describe shape, so a stripped-once result on the malformed form is
  # honest preservation, not a missed strip.
  defp strip_function_sentinels(nil), do: nil

  defp strip_function_sentinels(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, strip_function_sentinel_value(v)} end)
  end

  defp strip_function_sentinel_value(map) when is_map(map), do: strip_function_sentinels(map)

  defp strip_function_sentinel_value(list) when is_list(list), do: Enum.map(list, &strip_function_sentinel_value/1)

  defp strip_function_sentinel_value(@function_sentinel <> name) when name != "", do: name

  defp strip_function_sentinel_value(other), do: other

  # --- Derived: HTTP status map (Task 85) ---

  @doc """
  Derive a per-exchange HTTP-status → exception-class map from the
  assembled `handle_errors` data.

  When the caller supplies the precomputed `error_dispatch` (second arg),
  the dispatch channel is a pure projection (no re-walk of the AST).
  Two source channels are consulted; both are honest projections of
  already-extracted data (no new AST work when precomputed dispatch
  is threaded):

    1. `http_exceptions` — the static `describe().httpExceptions` map
       lifted into `handle_errors.http_exceptions` by Pipeline. Each
       entry surfaces as `source: "http_exceptions"`.
    2. `error_dispatch` predicates classified `predicate_kind:
       "http_status_eq"` — e.g. `if (code === 418) throw new
       DDoSProtection(...)` produces an entry under status `"418"`
       with `source: "throw_dispatch_predicate"`.

  Both sources may produce the same status code mapped to the same OR a
  different exception class — the shape preserves both so downstream
  consumers can detect drift. Output is a sorted map keyed by status
  string with sorted unique entries:

      %{
        "418" => [
          %{"class" => "DDoSProtection", "source" => "throw_dispatch_predicate"}
        ],
        "429" => [
          %{"class" => "RateLimitExceeded", "source" => "http_exceptions"}
        ]
      }

  Returns `nil` when the input is `nil` or when both channels are empty
  AND `http_exceptions` is `nil` (no data to project). Returns an
  empty map (`%{}`) when channels exist but contain no status entries
  — an honest "we looked, found nothing" signal.
  """
  @spec http_status_map(map() | nil, [map()] | nil) :: %{String.t() => [map()]} | nil
  def http_status_map(a, b \\ nil)
  def http_status_map(nil, _dispatch), do: nil

  def http_status_map(%{} = handle_errors, dispatch) do
    method = handle_errors["method"]
    http_exceptions = handle_errors["http_exceptions"]

    if is_nil(method) and not is_map(http_exceptions) do
      nil
    else
      from_http = http_exceptions_entries(http_exceptions)
      from_dispatch = predicate_status_entries(method, dispatch)

      from_http
      |> Kernel.++(from_dispatch)
      |> Enum.group_by(& &1["status"])
      |> Map.new(fn {status, list} ->
        {status, list |> Enum.map(&Map.delete(&1, "status")) |> Enum.uniq() |> Enum.sort()}
      end)
    end
  end

  def http_status_map(_, _), do: nil

  @spec http_exceptions_entries(term()) :: [%{String.t() => String.t()}]
  defp http_exceptions_entries(http_exceptions) when is_map(http_exceptions) do
    Enum.flat_map(http_exceptions, &http_exception_entry/1)
  end

  defp http_exceptions_entries(_), do: []

  # Mirror `dispatch_status_entry/1`'s numeric filter — `httpExceptions`
  # keys are HTTP status codes in practice, but a malformed describe()
  # could ship a non-numeric key. Skip those so `error_status_map`
  # honors its `^[0-9]+$` schema constraint without runtime failures.
  @spec http_exception_entry({term(), term()}) :: [%{String.t() => String.t()}]
  defp http_exception_entry({status, class}) when is_binary(class) do
    status_str = to_string(status)

    with true <- numeric_string?(status_str),
         normalized when not is_nil(normalized) <- normalize_class_name(class) do
      [%{"status" => status_str, "class" => normalized, "source" => "http_exceptions"}]
    else
      _ -> []
    end
  end

  defp http_exception_entry(_), do: []

  # Strip the `@function_sentinel` prefix (defined at the top of the
  # module) so the downstream classifier sees the bare class name. Pure
  # string literals (rare — e.g. an exchange that ships `"BadRequest"`
  # as text) pass through unchanged.
  defp normalize_class_name(class) when is_binary(class) do
    case class do
      @function_sentinel <> name when name != "" -> name
      "" -> nil
      other -> other
    end
  end

  defp normalize_class_name(_), do: nil

  @spec predicate_status_entries(term(), [map()] | nil) :: [%{String.t() => String.t()}]
  defp predicate_status_entries(_method, dispatch) when is_list(dispatch) do
    Enum.flat_map(dispatch, &dispatch_status_entry/1)
  end

  defp predicate_status_entries(method, nil) when is_map(method) do
    case ErrorDispatch.derive(method) do
      nil ->
        []

      entries when is_list(entries) ->
        Enum.flat_map(entries, &dispatch_status_entry/1)
    end
  end

  defp predicate_status_entries(_, _), do: []

  @spec dispatch_status_entry(term()) :: [%{String.t() => String.t()}]
  defp dispatch_status_entry(%{
         "exception_class" => class,
         "predicate_kind" => "http_status_eq",
         "predicate_values" => values
       })
       when is_binary(class) and is_list(values) do
    # `error_dispatch` classifies any `code === <literal>` as
    # `http_status_eq`, but `code` is overloaded in some exchanges
    # (e.g. bitstamp checks `code === 'API0005'` against an extracted
    # error-code field that happens to be named `code`). Filter to
    # numeric-string values so `error_status_map` stays HTTP-status-
    # shaped — non-numeric codes are honest exchange-specific lookups
    # better surfaced via `error_dispatch[].predicate_raw`.
    values
    |> Enum.map(&to_string/1)
    |> Enum.filter(&numeric_string?/1)
    |> Enum.map(fn status ->
      %{"status" => status, "class" => class, "source" => "throw_dispatch_predicate"}
    end)
  end

  defp dispatch_status_entry(_), do: []

  @spec numeric_string?(String.t()) :: boolean()
  defp numeric_string?(s) when is_binary(s), do: s != "" and String.match?(s, ~r/^[0-9]+$/)
  defp numeric_string?(_), do: false

  # --- Derived: retryable buckets (Task 86) ---

  @doc """
  Derive a per-exchange retry-classification map from the exception
  classes referenced in `handle_errors`.

  Walks every class name surfaced by the four channels Pipeline has
  already populated. When the caller threads a precomputed `error_dispatch`
  (second arg), the `error_dispatch[].exception_class` contribution is taken
  directly without re-deriving:

    * `http_exceptions` values (e.g. `"RateLimitExceeded"`)
    * `exceptions` values (broad/exact tables, plus market-type-
      specific keys like `spot`/`linear`)
    * `error_dispatch[].exception_class` (literal `throw new <X>` sites)
    * `throw_dispatches` exception classes are NOT included — those
      entries dispatch via lookup tables already covered by
      `exceptions` (the helper's first arg)

  Each class is bucketed via `ErrorHierarchy.bucket_for/1`:
  `rate_limit` / `auth` / `server_busy` / `network` / `non_retryable`.
  Output is a map of bucket name → sorted unique class list:

      %{
        "rate_limit" => ["DDoSProtection", "RateLimitExceeded"],
        "auth" => ["AuthenticationError"],
        "server_busy" => [],
        "network" => ["RequestTimeout"],
        "non_retryable" => ["BadRequest", "ExchangeError", "InvalidOrder"]
      }

  Buckets with zero referenced classes still appear with an empty list
  — the shape is constant so consumers don't need nil-checks. The
  classifier is honest about unrecognized classes: any class name not
  in the CCXT base hierarchy falls into `non_retryable`. The list
  preserves the unrecognized class names so consumers can audit.

  Returns `nil` when `handle_errors` is `nil`. Returns the constant
  empty-buckets shape (`%{"rate_limit" => [], ...}`) when handle_errors
  is non-nil but no exception class names are present.
  """
  @spec retryable_buckets(map() | nil, [map()] | nil) :: %{String.t() => [String.t()]} | nil
  def retryable_buckets(a, b \\ nil)
  def retryable_buckets(nil, _dispatch), do: nil

  def retryable_buckets(%{} = handle_errors, dispatch) do
    classes = collect_referenced_classes(handle_errors, dispatch)

    empty = Map.new(ErrorHierarchy.buckets(), &{&1, []})

    classes
    |> Enum.reduce(empty, fn class, acc ->
      bucket = ErrorHierarchy.bucket_for(class)
      Map.update!(acc, bucket, &[class | &1])
    end)
    |> Map.new(fn {bucket, list} -> {bucket, list |> Enum.uniq() |> Enum.sort()} end)
  end

  def retryable_buckets(_, _), do: nil

  @spec collect_referenced_classes(map(), [map()] | nil) :: [String.t()]
  defp collect_referenced_classes(handle_errors, dispatch) do
    from_http_exceptions(handle_errors["http_exceptions"]) ++
      from_exceptions(handle_errors["exceptions"]) ++
      from_dispatch(handle_errors["method"], dispatch)
  end

  @spec from_http_exceptions(term()) :: [String.t()]
  defp from_http_exceptions(map) when is_map(map) do
    map
    |> Map.values()
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&normalized_class_list/1)
  end

  defp from_http_exceptions(_), do: []

  # `exceptions` shape varies across exchanges:
  #
  #   * Standard 2-level: `%{"exact" => %{<code> => <class>}, "broad" => %{...}}`
  #   * Market-type-keyed 3-level: `%{"linear" => %{"exact" => %{...}}, "spot" => ...}`
  #     (binance USDM/COINM, bybit linear/inverse, okx variants)
  #   * Some exchanges go deeper still.
  #
  # Walk the value tree and collect every string leaf — non-string values
  # are skipped, sub-maps are walked through their own values. Non-binary
  # leaves (numbers, booleans, nil) are honest-empty.
  @spec from_exceptions(term()) :: [String.t()]
  defp from_exceptions(map) when is_map(map), do: collect_class_strings(map)
  defp from_exceptions(_), do: []

  @spec collect_class_strings(term()) :: [String.t()]
  defp collect_class_strings(map) when is_map(map) do
    map
    |> Map.values()
    |> Enum.flat_map(&collect_class_strings/1)
  end

  defp collect_class_strings(value) when is_binary(value), do: normalized_class_list(value)
  defp collect_class_strings(_), do: []

  @spec normalized_class_list(term()) :: [String.t()]
  defp normalized_class_list(value) do
    case normalize_class_name(value) do
      nil -> []
      name -> [name]
    end
  end

  @spec from_dispatch(term(), [map()] | nil) :: [String.t()]
  defp from_dispatch(_method, dispatch) when is_list(dispatch) do
    dispatch |> Enum.map(& &1["exception_class"]) |> Enum.filter(&is_binary/1)
  end

  defp from_dispatch(method, nil) when is_map(method) do
    case ErrorDispatch.derive(method) do
      nil -> []
      entries -> entries |> Enum.map(& &1["exception_class"]) |> Enum.filter(&is_binary/1)
    end
  end

  defp from_dispatch(_, _), do: []
end

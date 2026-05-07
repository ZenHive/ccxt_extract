defmodule CcxtExtract.Schema do
  @moduledoc """
  Build and validate per-exchange JSON output conforming to `exchange_v3.json`.

  Assembles data from all extraction layers into a single per-exchange map
  with three top-level sections: `exchange` (metadata), `runtime` (QuickBEAM
  values), and `structure` (OXC AST data).

  ## Schema Versioning

  The `schema_version` field in every output file follows a semver contract
  documented in `SCHEMA.md`. Consumers check this field to ensure compatibility.
  See `SCHEMA.md` for the full versioning contract, consumer guidance, and
  version history.

  ## Two-Layer Model

  - **runtime** — what an exchange IS: describe() config, symbols_index derived
    from loadMarkets()
  - **structure** — what an exchange DOES: class hierarchy, method signatures,
    sign / handleErrors AST bodies, overrides

  Since schema 3.0.0 (Task 117) the `runtime.markets` full snapshot,
  `structure.parse_methods` and `structure.ws_methods` are no longer emitted.
  The parse/ws method ASTs are still extracted to `priv/discoveries/*.json`
  for internal consumers (Phase 12 response parsing, Phase 15 WS dispatch).

  ## Two-State Optionality

  Each data field uses two states:
  - **Present with data** — extraction succeeded, value is a map/list
  - **null** — layer is missing, empty, or does not apply to this exchange type

  All keys are always materialized (never absent). Consumers check for null.
  Pipeline integrity stats and validation reports distinguish expected nulls
  from missing/corrupt discovery inputs that prevented usable data assembly.

  ### `_provenance` (required since schema 2.0.0)

  Every emitted exchange JSON carries a top-level `_provenance` map
  tagging each section as `raw`/`derived`/`override` (see
  `CcxtExtract.Provenance`). The field is required and non-null since
  schema 2.0.0 (Task 61c) — `validate/1` enforces presence via
  `@required_top_keys`, and `exchange_v3.json` enforces the object shape
  at JSV time.

  ## Usage

      exchange = CcxtExtract.Schema.build_exchange(meta, runtime, structure, ccxt_version: "4.5.45")
      :ok = CcxtExtract.Schema.validate(exchange)

  """

  alias CcxtExtract.SignRecipe

  @schema_version "3.1.0"
  @schema_filename "exchange_v3.json"

  @required_top_keys ~w(schema_version extracted_at ccxt_version exchange runtime structure _provenance)
  @required_exchange_keys ~w(id name alias)
  @required_runtime_keys ~w(describe symbols_index symbol_patterns url_templates testnet_urls request_headers)
  @required_structure_keys ~w(class_info methods sign_method authenticated_sections sign_recipe handle_errors interface_signatures pagination overrides unified_endpoints request_defaults)

  # --- Public API ---

  @doc "Returns the current schema version string."
  @spec schema_version() :: String.t()
  def schema_version, do: @schema_version

  @doc "Returns the current schema filename (JSON Schema file + output-dir copy)."
  @spec schema_filename() :: String.t()
  def schema_filename, do: @schema_filename

  @doc """
  Build a per-exchange output map conforming to `exchange_v3.json`.

  ## Parameters

    * `exchange_meta` — exchange identity map with keys: id, name, certified,
      pro, version, country, alias, referral
    * `runtime_data` — map with keys: describe, symbols_index, symbol_patterns,
      url_templates, testnet_urls, request_headers (each a map or nil; request_headers
      is always-present and always a wrapper map per Task 73b)
    * `structure_data` — map with keys: class_info, methods, sign_method,
      authenticated_sections, handle_errors, interface_signatures, pagination,
      overrides, unified_endpoints, request_defaults (each a map or nil)

  ## Options

    * `:ccxt_version` — CCXT version string (required)
    * `:extracted_at` — ISO 8601 timestamp (defaults to now)
  """
  @spec build_exchange(map(), map(), map(), keyword()) :: map()
  def build_exchange(exchange_meta, runtime_data, structure_data, opts \\ []) do
    ccxt_version = Keyword.fetch!(opts, :ccxt_version)

    extracted_at =
      Keyword.get_lazy(opts, :extracted_at, fn ->
        DateTime.to_iso8601(DateTime.utc_now())
      end)

    %{
      "schema_version" => @schema_version,
      "extracted_at" => extracted_at,
      "ccxt_version" => ccxt_version,
      "exchange" => build_exchange_section(exchange_meta),
      "runtime" => build_runtime_section(runtime_data),
      "structure" => build_structure_section(structure_data),
      "_provenance" => CcxtExtract.Provenance.build_default()
    }
  end

  @doc """
  Fast pre-flight validation of a per-exchange output map.

  Checks that the four required top-level sections exist with their required
  keys, and that the schema version matches. Returns `:ok` if valid,
  `{:error, reasons}` with a list of issues otherwise.

  This is intentionally lightweight — it only catches obviously malformed or
  incomplete maps before they reach the pipeline. For full draft 2020-12
  enforcement against `priv/schema/exchange_v3.json` (type checking, enum
  values, nested shapes, additionalProperties), use
  `CcxtExtract.Validation.validate_schema/2`.

  ## What was removed

  An earlier version of this function contained 800+ lines of hand-rolled
  structural checks that duplicated what the JSON Schema already enforces:
  nullable map checks, MethodAST shape, pagination entry validation, ClassInfo/
  ClassEntry required keys, MethodInventory/MethodSignature shapes,
  InterfaceSignature shapes, OverridesData/OverrideEntry shapes,
  HandleErrorsData, ErrorCodeFieldEntry, ThrowDispatchEntry, enum values for
  helpers/exceptions_source/roles/operators/lookup methods. All of those
  checks are now authoritative only in `exchange_v3.json` and enforced at
  pipeline output time via `CcxtExtract.Validation.validate_schema/2`.
  """
  @spec validate(map()) :: :ok | {:error, [String.t()]}
  def validate(data) when is_map(data) do
    errors =
      []
      |> check_required_keys(data, @required_top_keys, "top-level")
      |> check_schema_version(data)
      |> check_required_keys(data["exchange"], @required_exchange_keys, "exchange")
      |> check_required_keys(data["runtime"], @required_runtime_keys, "runtime")
      |> check_required_keys(data["structure"], @required_structure_keys, "structure")

    case errors do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  def validate(_), do: {:error, ["expected a map"]}

  @doc """
  Validate and raise on failure.
  """
  @spec validate!(map()) :: :ok
  def validate!(data) do
    case validate(data) do
      :ok -> :ok
      {:error, reasons} -> raise "Schema validation failed: #{Enum.join(reasons, "; ")}"
    end
  end

  # --- Section Builders ---

  defp build_exchange_section(meta) do
    %{
      "id" => meta["id"],
      "name" => meta["name"],
      "certified" => meta["certified"] || false,
      "pro" => meta["pro"] || false,
      "version" => meta["version"],
      "country" => meta["country"] || [],
      "alias" => meta["alias"] || false,
      "referral" => meta["referral"],
      "tier" => meta["id"] |> CcxtExtract.Tiers.get_priority_tier() |> Atom.to_string()
    }
  end

  defp build_runtime_section(data) do
    %{
      "describe" => data["describe"],
      "symbols_index" => data["symbols_index"],
      "symbol_patterns" => data["symbol_patterns"],
      "url_templates" => data["url_templates"],
      "testnet_urls" => data["testnet_urls"] || CcxtExtract.TestnetUrls.none_record(),
      "request_headers" => data["request_headers"] || CcxtExtract.RequestHeaders.empty_record()
    }
  end

  defp build_structure_section(data) do
    auth_sections = data["authenticated_sections"]
    sign_method = data["sign_method"]

    %{
      "class_info" => data["class_info"],
      "methods" => data["methods"],
      "sign_method" => sign_method,
      "authenticated_sections" => auth_sections,
      "sign_recipe" => SignRecipe.Derive.derive(sign_method, auth_sections),
      "handle_errors" => data["handle_errors"],
      "interface_signatures" => data["interface_signatures"],
      "pagination" => data["pagination"],
      "overrides" => data["overrides"],
      "unified_endpoints" => data["unified_endpoints"],
      "request_defaults" => data["request_defaults"]
    }
  end

  # --- Validation Helpers ---

  defp check_required_keys(errors, nil, _required, section) do
    ["#{section}: missing section" | errors]
  end

  defp check_required_keys(errors, data, required, section) when is_map(data) do
    missing = Enum.reject(required, &Map.has_key?(data, &1))

    case missing do
      [] -> errors
      keys -> ["#{section}: missing keys #{inspect(keys)}" | errors]
    end
  end

  defp check_required_keys(errors, _data, _required, section) do
    ["#{section}: expected a map" | errors]
  end

  defp check_schema_version(errors, %{"schema_version" => @schema_version}), do: errors

  defp check_schema_version(errors, %{"schema_version" => v}),
    do: ["schema_version: expected #{@schema_version}, got #{inspect(v)}" | errors]

  defp check_schema_version(errors, _), do: errors

  @doc false
  @spec type_name(term()) :: String.t()
  def type_name(val) when is_binary(val), do: "string"
  def type_name(val) when is_integer(val), do: "integer"
  def type_name(val) when is_float(val), do: "float"
  def type_name(val) when is_boolean(val), do: "boolean"
  def type_name(val) when is_list(val), do: "list"
  def type_name(val) when is_map(val), do: "map"
  def type_name(nil), do: "null"
  def type_name(_), do: "unknown"
end

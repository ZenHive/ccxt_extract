defmodule CcxtExtract.Schema do
  @moduledoc """
  Build and validate per-exchange JSON output conforming to `exchange_v1.json`.

  Assembles data from all extraction layers into a single per-exchange map
  with three top-level sections: `exchange` (metadata), `runtime` (QuickBEAM
  values), and `structure` (OXC AST data).

  ## Schema Versioning

  The `schema_version` field in every output file follows a semver contract
  documented in `SCHEMA.md`. Consumers check this field to ensure compatibility.
  See `SCHEMA.md` for the full versioning contract, consumer guidance, and
  version history.

  ## Two-Layer Model

  - **runtime** — what an exchange IS: describe() config, loadMarkets() data
  - **structure** — what an exchange DOES: class hierarchy, method signatures,
    method AST bodies (sign, handleErrors, parse*, ws*), overrides

  ## Two-State Optionality

  Each data field uses two states:
  - **Present with data** — extraction succeeded, value is a map/list
  - **null** — layer is missing, empty, or does not apply to this exchange type

  All keys are always materialized (never absent). Consumers check for null.
  Pipeline integrity stats and validation reports distinguish expected nulls
  from missing/corrupt discovery inputs that prevented usable data assembly.

  ## Usage

      exchange = CcxtExtract.Schema.build_exchange(meta, runtime, structure, ccxt_version: "4.5.45")
      :ok = CcxtExtract.Schema.validate(exchange)

  """

  @schema_version "1.5.0"

  @required_top_keys ~w(schema_version extracted_at ccxt_version exchange runtime structure)
  @required_exchange_keys ~w(id name alias)
  @required_runtime_keys ~w(describe markets symbol_patterns url_templates)
  @required_structure_keys ~w(class_info methods sign_method authenticated_sections handle_errors parse_methods ws_methods interface_signatures pagination overrides unified_endpoints)

  # --- Public API ---

  @doc "Returns the current schema version string."
  @spec schema_version() :: String.t()
  def schema_version, do: @schema_version

  @doc """
  Build a per-exchange output map conforming to `exchange_v1.json`.

  ## Parameters

    * `exchange_meta` — exchange identity map with keys: id, name, certified,
      pro, version, country, alias, referral
    * `runtime_data` — map with keys: describe, markets (each a map or nil)
    * `structure_data` — map with keys: class_info, methods, sign_method,
      handle_errors, parse_methods, ws_methods, overrides (each a map or nil)

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
      "structure" => build_structure_section(structure_data)
    }
  end

  @doc """
  Structural validation of a per-exchange output map.

  Returns `:ok` if valid, `{:error, reasons}` with a list of issues otherwise.
  Checks required keys, section shapes (map-or-null), and MethodAST key
  presence. Does NOT enforce scalar types, additionalProperties, or full
  JSON Schema conformance — use `CcxtExtract.Validation.validate_schema/2`
  for full draft 2020-12 enforcement against `priv/schema/exchange_v1.json`.
  """
  @spec validate(map()) :: :ok | {:error, [String.t()]}
  def validate(data) when is_map(data) do
    errors =
      []
      |> check_required_keys(data, @required_top_keys, "top-level")
      |> check_schema_version(data)
      |> check_exchange_section(data["exchange"])
      |> check_runtime_section(data["runtime"])
      |> check_structure_section(data["structure"])

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
      "referral" => meta["referral"]
    }
  end

  defp build_runtime_section(data) do
    %{
      "describe" => data["describe"],
      "markets" => data["markets"],
      "symbol_patterns" => data["symbol_patterns"],
      "url_templates" => data["url_templates"]
    }
  end

  defp build_structure_section(data) do
    %{
      "class_info" => data["class_info"],
      "methods" => data["methods"],
      "sign_method" => data["sign_method"],
      "authenticated_sections" => data["authenticated_sections"],
      "handle_errors" => data["handle_errors"],
      "parse_methods" => data["parse_methods"],
      "ws_methods" => data["ws_methods"],
      "interface_signatures" => data["interface_signatures"],
      "pagination" => data["pagination"],
      "overrides" => data["overrides"],
      "unified_endpoints" => data["unified_endpoints"]
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

  defp check_exchange_section(errors, section) do
    check_required_keys(errors, section, @required_exchange_keys, "exchange")
  end

  defp check_runtime_section(errors, section) do
    errors
    |> check_required_keys(section, @required_runtime_keys, "runtime")
    |> check_nullable_map(section, "describe", "runtime.describe")
    |> check_nullable_map(section, "markets", "runtime.markets")
    |> check_nullable_map(section, "symbol_patterns", "runtime.symbol_patterns")
    |> check_nullable_map(section, "url_templates", "runtime.url_templates")
  end

  defp check_structure_section(errors, section) do
    errors
    |> check_required_keys(section, @required_structure_keys, "structure")
    |> check_nullable_class_info(section, "class_info", "structure.class_info")
    |> check_nullable_method_inventory(section, "methods", "structure.methods")
    |> check_nullable_method_ast(section, "sign_method", "structure.sign_method")
    |> check_nullable_string_list(section, "authenticated_sections", "structure.authenticated_sections")
    |> check_nullable_handle_errors(section, "handle_errors", "structure.handle_errors")
    |> check_nullable_method_map(section, "parse_methods", "structure.parse_methods")
    |> check_nullable_method_map(section, "ws_methods", "structure.ws_methods")
    |> check_nullable_interface_signature_map(section, "interface_signatures", "structure.interface_signatures")
    |> check_nullable_pagination_map(section, "pagination", "structure.pagination")
    |> check_nullable_overrides(section, "overrides", "structure.overrides")
    |> check_nullable_string_list_map(section, "unified_endpoints", "structure.unified_endpoints")
  end

  # Value is nil or a list of strings
  defp check_nullable_string_list(errors, nil, _key, _label), do: errors

  defp check_nullable_string_list(errors, section, key, label) do
    case Map.get(section, key) do
      nil ->
        errors

      val when is_list(val) ->
        if Enum.all?(val, &is_binary/1) do
          errors
        else
          ["#{label}: expected list of strings, got list with non-string elements" | errors]
        end

      val ->
        ["#{label}: expected list of strings or null, got #{type_name(val)}" | errors]
    end
  end

  # Value is nil (allowed) or a map
  defp check_nullable_map(errors, nil, _key, _label), do: errors

  defp check_nullable_map(errors, section, key, label) do
    case Map.get(section, key) do
      nil -> errors
      val when is_map(val) -> errors
      val -> ["#{label}: expected map or null, got #{type_name(val)}" | errors]
    end
  end

  # Value is nil or a MethodAST map (must have "body" key)
  defp check_nullable_method_ast(errors, nil, _key, _label), do: errors

  defp check_nullable_method_ast(errors, section, key, label) do
    case Map.get(section, key) do
      nil -> errors
      val when is_map(val) -> check_method_ast_shape(errors, val, label)
      val -> ["#{label}: expected MethodAST map or null, got #{type_name(val)}" | errors]
    end
  end

  # Value is nil or a map of signature_name -> InterfaceSignature (name, params, return_type)
  defp check_nullable_interface_signature_map(errors, nil, _key, _label), do: errors

  defp check_nullable_interface_signature_map(errors, section, key, label) do
    case Map.get(section, key) do
      nil -> errors
      val when is_map(val) -> check_interface_signature_map_values(errors, val, label)
      val -> ["#{label}: expected map or null, got #{type_name(val)}" | errors]
    end
  end

  @required_interface_signature_keys ~w(name params return_type)
  defp check_interface_signature_map_values(errors, sig_map, label) do
    Enum.reduce(sig_map, errors, fn {name, value}, acc ->
      check_interface_signature_shape(acc, value, "#{label}.#{name}")
    end)
  end

  defp check_interface_signature_shape(errors, sig, label) when is_map(sig) do
    missing = Enum.reject(@required_interface_signature_keys, &Map.has_key?(sig, &1))

    case missing do
      [] -> errors
      keys -> ["#{label}: InterfaceSignature missing keys #{inspect(keys)}" | errors]
    end
  end

  defp check_interface_signature_shape(errors, value, label) do
    ["#{label}: expected InterfaceSignature map, got #{type_name(value)}" | errors]
  end

  # Value is nil or a map of method_name -> PaginationEntry (must have "strategy" key)
  defp check_nullable_pagination_map(errors, nil, _key, _label), do: errors

  defp check_nullable_pagination_map(errors, section, key, label) do
    case Map.get(section, key) do
      nil -> errors
      val when is_map(val) -> check_pagination_map_values(errors, val, label)
      val -> ["#{label}: expected map or null, got #{type_name(val)}" | errors]
    end
  end

  @valid_pagination_strategies ~w(dynamic deterministic cursor incremental)
  defp check_pagination_map_values(errors, pagination_map, label) do
    Enum.reduce(pagination_map, errors, fn {name, value}, acc ->
      check_pagination_entries(acc, value, "#{label}.#{name}")
    end)
  end

  # Pagination values are arrays of PaginationEntry maps
  defp check_pagination_entries(errors, entries, label) when is_list(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {entry, i}, acc ->
      check_pagination_entry_shape(acc, entry, "#{label}[#{i}]")
    end)
  end

  defp check_pagination_entries(errors, value, label) do
    ["#{label}: expected array of PaginationEntry, got #{type_name(value)}" | errors]
  end

  defp check_pagination_entry_shape(errors, entry, label) when is_map(entry) do
    errors
    |> check_pagination_strategy(entry, label)
    |> check_pagination_provenance(entry, label)
  end

  defp check_pagination_entry_shape(errors, value, label) do
    ["#{label}: expected PaginationEntry map, got #{type_name(value)}" | errors]
  end

  defp check_pagination_strategy(errors, entry, label) do
    case Map.get(entry, "strategy") do
      nil -> ["#{label}: PaginationEntry missing required key \"strategy\"" | errors]
      s when s in @valid_pagination_strategies -> errors
      s -> ["#{label}: unknown strategy #{inspect(s)}" | errors]
    end
  end

  # containing_method must be a string; target_method must be present (string or nil)
  defp check_pagination_provenance(errors, entry, label) do
    errors =
      case Map.get(entry, "containing_method") do
        s when is_binary(s) -> errors
        nil -> ["#{label}: PaginationEntry missing required key \"containing_method\"" | errors]
        v -> ["#{label}: PaginationEntry \"containing_method\" must be string, got #{type_name(v)}" | errors]
      end

    case Map.fetch(entry, "target_method") do
      {:ok, nil} ->
        errors

      {:ok, s} when is_binary(s) ->
        errors

      {:ok, v} ->
        ["#{label}: PaginationEntry \"target_method\" must be string or null, got #{type_name(v)}" | errors]

      :error ->
        ["#{label}: PaginationEntry missing required key \"target_method\"" | errors]
    end
  end

  # Value is nil or a map of method_name -> MethodAST
  defp check_nullable_method_map(errors, nil, _key, _label), do: errors

  defp check_nullable_method_map(errors, section, key, label) do
    case Map.get(section, key) do
      nil -> errors
      val when is_map(val) -> check_method_map_values(errors, val, label)
      val -> ["#{label}: expected map or null, got #{type_name(val)}" | errors]
    end
  end

  # Value is nil or a ClassInfo map with required rest entry
  defp check_nullable_class_info(errors, nil, _key, _label), do: errors

  defp check_nullable_class_info(errors, section, key, label) do
    case Map.get(section, key) do
      nil ->
        errors

      val when is_map(val) ->
        errors
        |> check_required_keys(val, ~w(rest), label)
        |> check_class_entry_field(val, "rest", "#{label}.rest")
        |> check_nullable_class_entry_field(val, "ws", "#{label}.ws")

      val ->
        ["#{label}: expected ClassInfo map or null, got #{type_name(val)}" | errors]
    end
  end

  # Value is nil or a MethodInventory map with required rest list
  defp check_nullable_method_inventory(errors, nil, _key, _label), do: errors

  defp check_nullable_method_inventory(errors, section, key, label) do
    case Map.get(section, key) do
      nil ->
        errors

      val when is_map(val) ->
        errors
        |> check_required_keys(val, ~w(rest), label)
        |> check_method_signature_list_field(val, "rest", "#{label}.rest")
        |> check_nullable_method_signature_list_field(val, "ws", "#{label}.ws")

      val ->
        ["#{label}: expected MethodInventory map or null, got #{type_name(val)}" | errors]
    end
  end

  # Value is nil or a HandleErrorsData map with required method/exceptions/http_exceptions
  defp check_nullable_handle_errors(errors, nil, _key, _label), do: errors

  defp check_nullable_handle_errors(errors, section, key, label) do
    case Map.get(section, key) do
      nil ->
        errors

      val when is_map(val) ->
        missing = Enum.reject(~w(method exceptions http_exceptions error_code_fields), &Map.has_key?(val, &1))

        case missing do
          [] ->
            errors
            |> check_required_method_ast_field(val, "method", "#{label}.method")
            |> check_nullable_map_field(val, "exceptions", "#{label}.exceptions")
            |> check_nullable_map_field(val, "http_exceptions", "#{label}.http_exceptions")
            |> check_error_code_fields(val, "error_code_fields", "#{label}.error_code_fields")

          keys ->
            ["#{label}: missing required keys #{inspect(keys)}" | errors]
        end

      val ->
        ["#{label}: expected HandleErrorsData map or null, got #{type_name(val)}" | errors]
    end
  end

  # error_code_fields must be a list of maps with required keys
  @required_error_code_field_keys ~w(object field method field2 roles sentinel_values)
  defp check_error_code_fields(errors, parent, key, label) do
    case Map.get(parent, key) do
      val when is_list(val) ->
        val
        |> Enum.with_index()
        |> Enum.reduce(errors, fn {entry, i}, acc ->
          check_error_code_field_entry(acc, entry, "#{label}[#{i}]")
        end)

      val ->
        ["#{label}: expected list, got #{type_name(val)}" | errors]
    end
  end

  @valid_roles ~w(error_code error_message status_sentinel)
  defp check_error_code_field_entry(errors, entry, label) when is_map(entry) do
    missing = Enum.reject(@required_error_code_field_keys, &Map.has_key?(entry, &1))

    case missing do
      [] ->
        errors
        |> check_roles(entry["roles"], label)
        |> check_sentinel_values(entry["sentinel_values"], label)

      keys ->
        ["#{label}: ErrorCodeFieldEntry missing keys #{inspect(keys)}" | errors]
    end
  end

  defp check_error_code_field_entry(errors, entry, label) do
    ["#{label}: expected ErrorCodeFieldEntry map, got #{type_name(entry)}" | errors]
  end

  # roles must be a list of valid role strings
  defp check_roles(errors, roles, label) when is_list(roles) do
    invalid = Enum.reject(roles, &(&1 in @valid_roles))

    case invalid do
      [] -> errors
      bad -> ["#{label}.roles: invalid values #{inspect(bad)}" | errors]
    end
  end

  defp check_roles(errors, roles, label) do
    ["#{label}.roles: expected list, got #{type_name(roles)}" | errors]
  end

  # sentinel_values must be null or a list of strings
  defp check_sentinel_values(errors, nil, _label), do: errors

  defp check_sentinel_values(errors, vals, label) when is_list(vals) do
    non_strings = Enum.reject(vals, &is_binary/1)

    case non_strings do
      [] -> errors
      bad -> ["#{label}.sentinel_values: expected strings, got #{inspect(bad)}" | errors]
    end
  end

  defp check_sentinel_values(errors, val, label) do
    ["#{label}.sentinel_values: expected null or list, got #{type_name(val)}" | errors]
  end

  defp check_method_ast_shape(errors, method, label) do
    required = ~w(async params return_type statements body)
    missing = Enum.reject(required, &Map.has_key?(method, &1))

    case missing do
      [] -> errors
      keys -> ["#{label}: MethodAST missing keys #{inspect(keys)}" | errors]
    end
  end

  defp check_method_map_values(errors, method_map, label) do
    Enum.reduce(method_map, errors, fn {name, value}, acc ->
      if is_map(value) do
        check_method_ast_shape(acc, value, "#{label}.#{name}")
      else
        ["#{label}.#{name}: expected MethodAST map, got #{type_name(value)}" | acc]
      end
    end)
  end

  @required_class_entry_keys ~w(node_key class_name extends_resolved parent_key file method_count)
  defp check_class_entry_field(errors, parent, key, label) do
    case Map.get(parent, key) do
      val when is_map(val) -> check_class_entry_shape(errors, val, label)
      val -> ["#{label}: expected ClassEntry map, got #{type_name(val)}" | errors]
    end
  end

  defp check_nullable_class_entry_field(errors, parent, key, label) do
    case Map.get(parent, key) do
      nil -> errors
      val when is_map(val) -> check_class_entry_shape(errors, val, label)
      val -> ["#{label}: expected ClassEntry map or null, got #{type_name(val)}" | errors]
    end
  end

  defp check_class_entry_shape(errors, entry, label) do
    missing = Enum.reject(@required_class_entry_keys, &Map.has_key?(entry, &1))

    case missing do
      [] ->
        errors
        |> check_string_field(entry["node_key"], "#{label}.node_key")
        |> check_string_field(entry["class_name"], "#{label}.class_name")
        |> check_string_field(entry["extends_resolved"], "#{label}.extends_resolved")
        |> check_string_field(entry["parent_key"], "#{label}.parent_key")
        |> check_string_field(entry["file"], "#{label}.file")
        |> check_integer_field(entry["method_count"], "#{label}.method_count")

      keys ->
        ["#{label}: ClassEntry missing keys #{inspect(keys)}" | errors]
    end
  end

  @required_method_signature_keys ~w(name async params return_type statements)
  defp check_method_signature_list_field(errors, parent, key, label) do
    case Map.get(parent, key) do
      val when is_list(val) -> check_method_signature_list(errors, val, label)
      val -> ["#{label}: expected list, got #{type_name(val)}" | errors]
    end
  end

  defp check_nullable_method_signature_list_field(errors, parent, key, label) do
    case Map.get(parent, key) do
      nil -> errors
      val when is_list(val) -> check_method_signature_list(errors, val, label)
      val -> ["#{label}: expected list or null, got #{type_name(val)}" | errors]
    end
  end

  defp check_method_signature_list(errors, signatures, label) do
    signatures
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {signature, index}, acc ->
      check_method_signature_shape(acc, signature, "#{label}[#{index}]")
    end)
  end

  defp check_method_signature_shape(errors, signature, label) when is_map(signature) do
    missing = Enum.reject(@required_method_signature_keys, &Map.has_key?(signature, &1))

    case missing do
      [] ->
        errors
        |> check_string_field(signature["name"], "#{label}.name")
        |> check_boolean_field(signature["async"], "#{label}.async")
        |> check_list_field(signature["params"], "#{label}.params")
        |> check_string_or_nil_field(signature["return_type"], "#{label}.return_type")
        |> check_integer_field(signature["statements"], "#{label}.statements")

      keys ->
        ["#{label}: MethodSignature missing keys #{inspect(keys)}" | errors]
    end
  end

  defp check_method_signature_shape(errors, signature, label) do
    ["#{label}: expected MethodSignature map, got #{type_name(signature)}" | errors]
  end

  defp check_required_method_ast_field(errors, parent, key, label) do
    case Map.get(parent, key) do
      val when is_map(val) -> check_method_ast_shape(errors, val, label)
      val -> ["#{label}: expected MethodAST map, got #{type_name(val)}" | errors]
    end
  end

  defp check_nullable_map_field(errors, parent, key, label) do
    case Map.get(parent, key) do
      nil -> errors
      val when is_map(val) -> errors
      val -> ["#{label}: expected map or null, got #{type_name(val)}" | errors]
    end
  end

  # Value is nil or an OverridesData map with extends/rest/ws keys
  defp check_nullable_overrides(errors, nil, _key, _label), do: errors

  defp check_nullable_overrides(errors, section, key, label) do
    case Map.get(section, key) do
      nil ->
        errors

      val when is_map(val) ->
        errors
        |> check_overrides_required_keys(val, label)
        |> check_override_entry(val, "rest", "#{label}.rest")
        |> check_override_entry(val, "ws", "#{label}.ws")

      val ->
        ["#{label}: expected OverridesData map or null, got #{type_name(val)}" | errors]
    end
  end

  @required_overrides_keys ~w(extends rest ws)
  defp check_overrides_required_keys(errors, overrides, label) do
    missing = Enum.reject(@required_overrides_keys, &Map.has_key?(overrides, &1))

    case missing do
      [] -> check_extends_type(errors, overrides["extends"], label)
      keys -> ["#{label}: missing required keys #{inspect(keys)}" | errors]
    end
  end

  defp check_extends_type(errors, val, _label) when is_binary(val), do: errors

  defp check_extends_type(errors, val, label) do
    ["#{label}.extends: expected string, got #{type_name(val)}" | errors]
  end

  defp check_parent_key_type(errors, val, _label) when is_binary(val), do: errors

  defp check_parent_key_type(errors, val, label) do
    ["#{label}.parent_key: expected string, got #{type_name(val)}" | errors]
  end

  # Type-guard wrapper: only calls check_method_map_values if the field is actually a map
  # overridden and new_methods are required objects in the JSON Schema (not nullable)
  defp check_required_method_map_field(errors, parent, key, label) do
    case Map.get(parent, key) do
      val when is_map(val) -> check_method_map_values(errors, val, label)
      val -> ["#{label}: expected map, got #{type_name(val)}" | errors]
    end
  end

  defp check_inherited_type(errors, val, label) when is_list(val) do
    if Enum.all?(val, &is_binary/1) do
      errors
    else
      non_strings = Enum.reject(val, &is_binary/1)
      ["#{label}.inherited: expected all strings, got non-string elements: #{inspect(non_strings)}" | errors]
    end
  end

  defp check_inherited_type(errors, val, label) do
    ["#{label}.inherited: expected list, got #{type_name(val)}" | errors]
  end

  @required_override_entry_keys ~w(parent_key overridden new_methods inherited)
  defp check_override_entry(errors, overrides, key, label) do
    case Map.get(overrides, key) do
      nil ->
        errors

      val when is_map(val) ->
        missing = Enum.reject(@required_override_entry_keys, &Map.has_key?(val, &1))

        case missing do
          [] ->
            errors
            |> check_parent_key_type(val["parent_key"], label)
            |> check_required_method_map_field(val, "overridden", "#{label}.overridden")
            |> check_required_method_map_field(val, "new_methods", "#{label}.new_methods")
            |> check_inherited_type(Map.get(val, "inherited"), label)

          keys ->
            ["#{label}: OverrideEntry missing keys #{inspect(keys)}" | errors]
        end

      val ->
        ["#{label}: expected OverrideEntry map or null, got #{type_name(val)}" | errors]
    end
  end

  defp check_string_field(errors, val, _label) when is_binary(val), do: errors
  defp check_string_field(errors, val, label), do: ["#{label}: expected string, got #{type_name(val)}" | errors]

  defp check_string_or_nil_field(errors, val, _label) when is_binary(val) or is_nil(val), do: errors

  defp check_string_or_nil_field(errors, val, label) do
    ["#{label}: expected string or null, got #{type_name(val)}" | errors]
  end

  defp check_boolean_field(errors, val, _label) when is_boolean(val), do: errors
  defp check_boolean_field(errors, val, label), do: ["#{label}: expected boolean, got #{type_name(val)}" | errors]

  defp check_integer_field(errors, val, _label) when is_integer(val), do: errors
  defp check_integer_field(errors, val, label), do: ["#{label}: expected integer, got #{type_name(val)}" | errors]

  defp check_list_field(errors, val, _label) when is_list(val), do: errors
  defp check_list_field(errors, val, label), do: ["#{label}: expected list, got #{type_name(val)}" | errors]

  # Value is nil or a map where each value is a list of strings
  defp check_nullable_string_list_map(errors, nil, _key, _label), do: errors

  defp check_nullable_string_list_map(errors, section, key, label) do
    case Map.get(section, key) do
      nil ->
        errors

      val when is_map(val) ->
        Enum.reduce(val, errors, fn {name, value}, acc ->
          check_string_list_entry(acc, value, "#{label}.#{name}")
        end)

      val ->
        ["#{label}: expected map or null, got #{type_name(val)}" | errors]
    end
  end

  defp check_string_list_entry(errors, value, label) when is_list(value) do
    if Enum.all?(value, &is_binary/1) do
      errors
    else
      ["#{label}: expected list of strings, got list with non-string elements" | errors]
    end
  end

  defp check_string_list_entry(errors, value, label) do
    ["#{label}: expected list of strings, got #{type_name(value)}" | errors]
  end

  defp type_name(val) when is_binary(val), do: "string"
  defp type_name(val) when is_integer(val), do: "integer"
  defp type_name(val) when is_float(val), do: "float"
  defp type_name(val) when is_boolean(val), do: "boolean"
  defp type_name(val) when is_list(val), do: "list"
  defp type_name(val) when is_map(val), do: "map"
  defp type_name(nil), do: "null"
  defp type_name(_), do: "unknown"
end

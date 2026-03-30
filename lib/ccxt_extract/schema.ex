defmodule CcxtExtract.Schema do
  @moduledoc """
  Build and validate per-exchange JSON output conforming to `exchange_v1.json`.

  Assembles data from all extraction layers into a single per-exchange map
  with three top-level sections: `exchange` (metadata), `runtime` (QuickBEAM
  values), and `structure` (OXC AST data).

  ## Two-Layer Model

  - **runtime** — what an exchange IS: describe() config, loadMarkets() data
  - **structure** — what an exchange DOES: class hierarchy, method signatures,
    method AST bodies (sign, handleErrors, parse*, ws*), overrides

  ## Two-State Optionality

  Each data field uses two states:
  - **Present with data** — extraction succeeded, value is a map/list
  - **null** — layer is missing, empty, or does not apply to this exchange type

  All keys are always materialized (never absent). Consumers check for null.

  ## Usage

      exchange = CcxtExtract.Schema.build_exchange(meta, runtime, structure, ccxt_version: "4.5.45")
      :ok = CcxtExtract.Schema.validate(exchange)
  """

  @schema_version "1.0"

  @required_top_keys ~w(schema_version extracted_at ccxt_version exchange runtime structure)
  @required_exchange_keys ~w(id name alias)
  @required_runtime_keys ~w(describe markets)
  @required_structure_keys ~w(class_info methods sign_method handle_errors parse_methods ws_methods overrides)

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
  JSON Schema conformance — that is Task 16 (use `priv/schema/exchange_v1.json`
  with a JSON Schema validator for full enforcement).
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
      "markets" => data["markets"]
    }
  end

  defp build_structure_section(data) do
    %{
      "class_info" => data["class_info"],
      "methods" => data["methods"],
      "sign_method" => data["sign_method"],
      "handle_errors" => data["handle_errors"],
      "parse_methods" => data["parse_methods"],
      "ws_methods" => data["ws_methods"],
      "overrides" => data["overrides"]
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
  end

  defp check_structure_section(errors, section) do
    errors
    |> check_required_keys(section, @required_structure_keys, "structure")
    |> check_nullable_map(section, "class_info", "structure.class_info")
    |> check_nullable_map(section, "methods", "structure.methods")
    |> check_nullable_method_ast(section, "sign_method", "structure.sign_method")
    |> check_nullable_map(section, "handle_errors", "structure.handle_errors")
    |> check_nullable_method_map(section, "parse_methods", "structure.parse_methods")
    |> check_nullable_method_map(section, "ws_methods", "structure.ws_methods")
    |> check_nullable_overrides(section, "overrides", "structure.overrides")
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

  # Value is nil or a map of method_name -> MethodAST
  defp check_nullable_method_map(errors, nil, _key, _label), do: errors

  defp check_nullable_method_map(errors, section, key, label) do
    case Map.get(section, key) do
      nil -> errors
      val when is_map(val) -> check_method_map_values(errors, val, label)
      val -> ["#{label}: expected map or null, got #{type_name(val)}" | errors]
    end
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

  defp type_name(val) when is_binary(val), do: "string"
  defp type_name(val) when is_integer(val), do: "integer"
  defp type_name(val) when is_float(val), do: "float"
  defp type_name(val) when is_boolean(val), do: "boolean"
  defp type_name(val) when is_list(val), do: "list"
  defp type_name(val) when is_map(val), do: "map"
  defp type_name(nil), do: "null"
  defp type_name(_), do: "unknown"
end

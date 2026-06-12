defmodule CcxtExtract.Schema do
  @moduledoc """
  Build and validate per-exchange JSON output conforming to `exchange_v4.json`.

  v4 assembles extraction-layer data into consumer-shaped top-level sections
  (`endpoints`, `auth`, `errors`, `rate_limits`, `normalization`,
  `websocket`, `markets`, `testnet`, `raw`).

  ## Schema Versioning

  The `schema_version` field in every output file follows a semver contract
  documented in `SCHEMA.md`. Consumers check this field to ensure compatibility.
  See `SCHEMA.md` for the full versioning contract, consumer guidance, and
  version history.

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
  `@required_top_keys`, and `exchange_v4.json` enforces the object shape
  at JSV time.

  ## Usage

      exchange = CcxtExtract.Schema.build_exchange(meta, runtime, structure, ccxt_version: "4.5.45")
      :ok = CcxtExtract.Schema.validate(exchange)

  """

  alias CcxtExtract.Provenance
  alias CcxtExtract.RequestShape
  alias CcxtExtract.SignRecipe
  alias CcxtExtract.TransactionClassification

  @schema_version "4.1.0"
  @schema_filename "exchange_v4.json"

  @required_exchange_keys ~w(id name alias)

  @required_top_keys ~w(schema_version extracted_at ccxt_version exchange endpoints auth errors rate_limits normalization websocket markets testnet raw _provenance)
  @required_endpoints_keys ~w(unified descriptors interfaces pagination request transaction_classification handlers)
  @required_endpoints_request_keys ~w(defaults shape)
  @required_endpoints_handlers_keys ~w(error signing parse)
  @required_auth_keys ~w(sign_recipe sign_method authenticated_sections headers)
  @required_errors_keys ~w(handle_errors class_hierarchy status_map retry_classification)
  @required_rate_limits_keys ~w(buckets per_endpoint_cost endpoint_cost_binding)
  @required_markets_keys ~w(symbols_index patterns currencies precision_mode)
  @required_raw_keys ~w(describe url_templates class_info method_inventory overrides_meta)
  @required_normalization_keys ~w(parse_methods_digest field_maps response_envelopes)
  @required_websocket_keys ~w(heartbeat auth subscribe dispatch orderbook_semantics trades_semantics ohlcv_semantics)

  # --- Public API ---

  @doc "Returns the current (v4) schema version string."
  @spec schema_version() :: String.t()
  def schema_version, do: @schema_version

  @doc "Returns the current (v4) schema filename (JSON Schema file + output-dir copy)."
  @spec schema_filename() :: String.t()
  def schema_filename, do: @schema_filename

  @doc """
  Build a per-exchange output map conforming to `exchange_v4.json`.

  v4 assembles extraction-layer data into consumer-shaped top-level groups
  (`endpoints`, `auth`, `errors`, `rate_limits`, `normalization`,
  `websocket`, `markets`, `testnet`, `raw`).

  ## Parameters

  Inputs come straight from `Pipeline.build_exchange_data/3`.

  ## Populated subsections

  `rate_limits.buckets` is populated as of Task 89 — see
  `CcxtExtract.RateLimitBuckets`.

  `rate_limits.per_endpoint_cost` mirrors `structure.rate_limit_costs`
  (Task 90 slice B — same map or JSON null). `rate_limits.endpoint_cost_binding`
  mirrors `structure.endpoint_cost_binding` (bucket index + axes, or null).

  `normalization` is the Task 129 carrier — `parse_methods_digest`
  (compact, AST-free signature digest projected from
  `priv/discoveries/parse_methods.json`), plus `field_maps` and
  `response_envelopes` scaffolds populated by Phase 12 sub-bundles.

  ## Out of scope (Task 130)

  Phase 12 sub-bundles flip the `field_maps` /
  `response_envelopes` stubs from null to populated. DO NOT
  pre-populate either here beyond the Task 129 scaffold — keep the v4
  normalization carrier additive.
  """
  @spec build_exchange(map(), map(), map(), keyword()) :: map()
  def build_exchange(exchange_meta, runtime_data, structure_data, opts \\ []) do
    ccxt_version = Keyword.fetch!(opts, :ccxt_version)

    extracted_at =
      Keyword.get_lazy(opts, :extracted_at, fn ->
        CcxtExtract.Clock.timestamp(:extracted_at)
      end)

    auth_sections = structure_data["authenticated_sections"]
    sign_method = structure_data["sign_method"]
    describe_api = structure_data["describe_api"]
    normalization = Keyword.get(opts, :normalization) || CcxtExtract.Normalization.build(nil, nil)

    websocket =
      Keyword.get(opts, :websocket) ||
        %{
          "heartbeat" => CcxtExtract.WsHeartbeat.none_record(),
          "auth" => CcxtExtract.WsAuth.none_record(),
          "subscribe" => CcxtExtract.WsSubscribe.none_record(),
          "dispatch" => CcxtExtract.WsDispatch.none_record(),
          "orderbook_semantics" => CcxtExtract.WsOrderbookSemantics.none_record(),
          "trades_semantics" => CcxtExtract.WsTradesSemantics.none_record(),
          "ohlcv_semantics" => CcxtExtract.WsOhlcvSemantics.none_record()
        }

    %{
      "schema_version" => @schema_version,
      "extracted_at" => extracted_at,
      "ccxt_version" => ccxt_version,
      "exchange" => build_exchange_section(exchange_meta),
      "endpoints" => %{
        "unified" => structure_data["unified_endpoints"],
        "descriptors" => structure_data["method_descriptors"],
        "transaction_classification" =>
          TransactionClassification.derive(
            structure_data["unified_endpoints"],
            structure_data["raw_broadcast"],
            describe_api
          ),
        "interfaces" => structure_data["interface_signatures"],
        "pagination" => structure_data["pagination"],
        "request" => %{
          "defaults" => structure_data["request_defaults"],
          "shape" => RequestShape.Derive.derive(sign_method, auth_sections, describe_api)
        },
        "handlers" => %{
          "error" => structure_data["error_dispatch"],
          "signing" => structure_data["sign_dispatch"],
          "parse" => structure_data["parse_dispatch"]
        }
      },
      "auth" => %{
        "sign_recipe" => SignRecipe.Derive.derive(sign_method, auth_sections),
        "sign_method" => sign_method,
        "authenticated_sections" => auth_sections,
        "headers" => runtime_data["request_headers"] || CcxtExtract.RequestHeaders.empty_record()
      },
      "errors" => %{
        "handle_errors" => structure_data["handle_errors"],
        "class_hierarchy" => structure_data["error_class_hierarchy"],
        "status_map" => structure_data["error_status_map"],
        "retry_classification" => structure_data["error_retryable"]
      },
      "rate_limits" => %{
        "buckets" => structure_data["rate_limit_buckets"] || CcxtExtract.RateLimitBuckets.empty_record(),
        "per_endpoint_cost" => structure_data["rate_limit_costs"],
        "endpoint_cost_binding" => structure_data["endpoint_cost_binding"]
      },
      "normalization" => normalization,
      "websocket" => websocket,
      "markets" => %{
        "symbols_index" => runtime_data["symbols_index"],
        "patterns" => runtime_data["symbol_patterns"],
        "currencies" => runtime_data["currencies"],
        "precision_mode" => runtime_data["precision_mode"]
      },
      "testnet" => runtime_data["testnet_urls"] || CcxtExtract.TestnetUrls.none_record(),
      "raw" => %{
        "describe" => runtime_data["describe"],
        "url_templates" => runtime_data["url_templates"],
        "class_info" => structure_data["class_info"],
        "method_inventory" => structure_data["methods"],
        "overrides_meta" => structure_data["overrides"]
      },
      "_provenance" => Provenance.build_default()
    }
  end

  @doc """
  Lightweight pre-flight validation for v4 outputs.

  Checks the top-level groups and their required keys, plus the schema
  version. Full draft-2020-12 enforcement against `priv/schema/exchange_v4.json`
  happens in `CcxtExtract.Validation.validate_schema/2`.
  """
  @spec validate(map()) :: :ok | {:error, [String.t()]}
  def validate(data) when is_map(data) do
    errors =
      []
      |> check_required_keys(data, @required_top_keys, "top-level")
      |> check_schema_version(data)
      |> check_required_keys(data["exchange"], @required_exchange_keys, "exchange")
      |> check_required_keys(data["endpoints"], @required_endpoints_keys, "endpoints")
      |> check_required_keys(
        get_in(data, ["endpoints", "request"]),
        @required_endpoints_request_keys,
        "endpoints.request"
      )
      |> check_required_keys(
        get_in(data, ["endpoints", "handlers"]),
        @required_endpoints_handlers_keys,
        "endpoints.handlers"
      )
      |> check_required_keys(data["auth"], @required_auth_keys, "auth")
      |> check_required_keys(data["errors"], @required_errors_keys, "errors")
      |> check_required_keys(data["rate_limits"], @required_rate_limits_keys, "rate_limits")
      |> check_required_keys(data["markets"], @required_markets_keys, "markets")
      |> check_required_keys(data["raw"], @required_raw_keys, "raw")
      |> check_required_keys(data["normalization"], @required_normalization_keys, "normalization")
      |> check_required_keys(data["websocket"], @required_websocket_keys, "websocket")

    case errors do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  def validate(_), do: {:error, ["expected a map"]}

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

defmodule CcxtExtract.Provenance do
  @moduledoc """
  Per-field provenance tagging for the three-tier extraction model
  (raw / derived / override).

  Every emitted per-exchange JSON carries a top-level `_provenance` map keyed
  by RFC 6901 JSON Pointer paths into the payload. Values are one of:

    * `"raw"` — straight passthrough from a discovery file (QuickBEAM
      runtime or OXC AST extractor). The pipeline did not transform it.
    * `"derived"` — computed by a derivation module at assembly time
      (e.g. `SymbolPatterns.derive/2`, `AuthenticatedSections.derive/2`).
      Still AST-provable; no hand-curation.
    * `"override"` — replaced at the tail of `Pipeline.extract/1` by an
      entry in `priv/overrides/<id>.json`. Carries a required `reason`
      in the override file.

  ## Design

  The map is flat and lives alongside the main payload rather than inline
  per-field tuples. This keeps the emitted JSON clean (consumers that don't
  care about provenance ignore one top-level key) and is cheap to update
  when overrides land (a single pointer replaces one flat entry, not a
  recursive merge into nested maps).

  Granularity is section + direct children — enough to answer "did this
  field come from CCXT or from us?" without exploding map size on huge
  sections like `/runtime/markets`. The `/structure/handle_errors` section
  is mixed (three raw keys, two derived) so it carries per-subkey tags.

  The default map is CONSTANT across exchanges — it describes the SHAPE of
  the schema, not the current value. If a field is `null` for a given
  exchange, the provenance still says where it WOULD have come from, which
  matches the Honesty Rule: null carries a reason, provenance carries a
  lineage, the two are orthogonal.

  ## Schema bump

  Introduced additively in `schema_version: "1.8.1"` (nullable). Promoted
  to required, non-null at `schema_version: "2.0.0"` by Task 61c —
  `exchange_v3.json` enforces the object shape at JSV time and
  `Schema.validate/1` enforces presence via `@required_top_keys`.

  Schema 3.0.0 (Task 117) pruned `/runtime/markets`,
  `/structure/parse_methods`, and `/structure/ws_methods` from the raw
  pointer set. `/runtime/symbols_index` was added as a derived pointer —
  it replaces the `runtime.markets.markets` full snapshot with a compact
  `{symbol => {spot: bool, swap: bool}}` index.

  ## Usage

      provenance =
        Provenance.build_default()
        |> Provenance.stamp_overrides(["/structure/authenticated_sections"])
  """

  @raw_pointers ~w(
    /exchange/id
    /exchange/name
    /exchange/certified
    /exchange/pro
    /exchange/version
    /exchange/country
    /exchange/alias
    /exchange/referral
    /runtime/describe
    /runtime/url_templates
    /runtime/request_headers
    /structure/class_info
    /structure/methods
    /structure/sign_method
    /structure/handle_errors/method
    /structure/handle_errors/exceptions
    /structure/handle_errors/http_exceptions
    /structure/interface_signatures
    /structure/pagination
    /structure/overrides
  )

  @derived_pointers ~w(
    /exchange/tier
    /runtime/symbols_index
    /runtime/symbol_patterns
    /runtime/testnet_urls
    /structure/authenticated_sections
    /structure/sign_recipe
    /structure/request_shape
    /structure/handle_errors/error_code_fields
    /structure/handle_errors/throw_dispatches
    /structure/unified_endpoints
    /structure/request_defaults
  )

  # v4 pointer paths — same content as v3 under reorganized top-level
  # groups. Used by `build_default_v4/0` when emission targets v4 via
  # `--schema-target=4`. Pointers track `SCHEMA.md` § "Top-level reshape".
  @raw_pointers_v4 ~w(
    /exchange/id
    /exchange/name
    /exchange/certified
    /exchange/pro
    /exchange/version
    /exchange/country
    /exchange/alias
    /exchange/referral
    /raw/describe
    /raw/url_templates
    /raw/class_info
    /raw/method_inventory
    /raw/overrides_meta
    /auth/sign_method
    /auth/headers
    /errors/handle_errors/method
    /errors/handle_errors/exceptions
    /errors/handle_errors/http_exceptions
    /endpoints/interfaces
    /endpoints/pagination
  )

  @derived_pointers_v4 ~w(
    /exchange/tier
    /markets/symbols_index
    /markets/patterns
    /testnet
    /auth/authenticated_sections
    /auth/sign_recipe
    /endpoints/request/shape
    /errors/handle_errors/error_code_fields
    /errors/handle_errors/throw_dispatches
    /endpoints/unified
    /endpoints/request/defaults
  )

  @doc """
  Returns the constant default provenance map for a freshly-assembled
  exchange (before any overrides have been applied).
  """
  @spec build_default() :: %{String.t() => String.t()}
  def build_default do
    raw = Map.new(@raw_pointers, &{&1, "raw"})
    derived = Map.new(@derived_pointers, &{&1, "derived"})
    Map.merge(raw, derived)
  end

  @doc """
  Returns the constant default provenance map for a v4-shaped exchange.
  Same content as `build_default/0` mapped onto v4 pointer paths
  (Task 130 — gated, opt-in via `--schema-target=4`).
  """
  @spec build_default_v4() :: %{String.t() => String.t()}
  def build_default_v4 do
    raw = Map.new(@raw_pointers_v4, &{&1, "raw"})
    derived = Map.new(@derived_pointers_v4, &{&1, "derived"})
    Map.merge(raw, derived)
  end

  @doc "v4 raw pointers. Exposed for tests and future contract invariants."
  @spec raw_pointers_v4() :: [String.t()]
  def raw_pointers_v4, do: @raw_pointers_v4

  @doc "v4 derived pointers. Exposed for tests and future contract invariants."
  @spec derived_pointers_v4() :: [String.t()]
  def derived_pointers_v4, do: @derived_pointers_v4

  @doc """
  Overwrite provenance entries at each given JSON Pointer path with
  `"override"`. Paths that weren't in the default map are added — this
  lets override files tag sub-tree paths (e.g. `/structure/sign_method/params`)
  that are deeper than the default's granularity.
  """
  @spec stamp_overrides(%{String.t() => String.t()}, [String.t()]) ::
          %{String.t() => String.t()}
  def stamp_overrides(provenance, override_paths) when is_map(provenance) and is_list(override_paths) do
    Enum.reduce(override_paths, provenance, fn path, acc ->
      Map.put(acc, path, "override")
    end)
  end

  @doc """
  List of JSON Pointer strings tagged `"raw"` in the default map.
  Exposed for tests and `validate/1`.
  """
  @spec raw_pointers() :: [String.t()]
  def raw_pointers, do: @raw_pointers

  @doc """
  List of JSON Pointer strings tagged `"derived"` in the default map.
  Exposed for tests and `validate/1`.
  """
  @spec derived_pointers() :: [String.t()]
  def derived_pointers, do: @derived_pointers

  @doc """
  Validate a provenance map: every value must be one of the three allowed
  tags, and every key must be a JSON Pointer string starting with `/`.

  Returns `:ok` or `{:error, [reason_string]}`.
  """
  @spec validate(term()) :: :ok | {:error, [String.t()]}
  def validate(map) when is_map(map) do
    errors =
      Enum.reduce(map, [], fn {k, v}, acc ->
        acc =
          if is_binary(k) and String.starts_with?(k, "/") do
            acc
          else
            ["key #{inspect(k)} is not a JSON Pointer string starting with '/'" | acc]
          end

        if v in ["raw", "derived", "override"] do
          acc
        else
          ["value #{inspect(v)} at #{inspect(k)} must be one of raw/derived/override" | acc]
        end
      end)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  def validate(_), do: {:error, ["_provenance must be a map"]}
end

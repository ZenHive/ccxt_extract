defmodule CcxtExtract.Normalization do
  @moduledoc """
  Carrier for the v4 `normalization` block.

  Projects per-exchange `parse*` method ASTs (extracted to
  `priv/discoveries/parse_methods.json`) into a compact, AST-free digest
  and scaffolds the `field_maps` / `response_envelopes` sections that
  Phase 12 sub-bundles populate later.

  ## Why compact (no AST body)

  Schema 3.0.0 (Task 117) dropped `structure.parse_methods` from emitted
  per-exchange JSON because re-emitting the full ESTree bodies blew the
  Hex 128 MB publish cap that `ccxt_client` downstream needs cleared.
  This module re-introduces the surface as a **compact digest** —
  method name → `{params, return_type, async, statement_count}` — and
  preserves the 91.6% Hex-cap reduction. Full bodies remain in
  `priv/discoveries/parse_methods.json` for internal Phase 12 derivation
  consumers.

  ## Output Structure

      %{
        "parse_methods_digest" => %{method_name => digest_record(), ...},
        "field_maps" => stub_record(),
        "response_envelopes" => stub_record()
      }

  Each `digest_record/0` is `%{params, return_type, async, statement_count}`.
  `field_maps` and `response_envelopes` carry one key per parser type
  (`ticker`/`trade`/`ohlcv`/`order`/`position`/`balance`/`market`/
  `transaction`/`deposit_address`), each `null` until Phase 12 sub-bundles
  (Tasks 74–83) populate them, plus a top-level `_unresolved_reason:
  "not_yet_derived"` mirroring the SignRecipe scaffold convention.

  ## Pure Derivation

  No IO, no QuickBEAM, no AST traversal beyond reading the already-loaded
  `parse_methods` discovery entry. Microsecond-scale; called inline during
  pipeline assembly under the v4 schema-target path only.
  """

  alias CcxtExtract.Normalization.Balance
  alias CcxtExtract.Normalization.DepositAddress
  alias CcxtExtract.Normalization.Market
  alias CcxtExtract.Normalization.OHLCV
  alias CcxtExtract.Normalization.Order
  alias CcxtExtract.Normalization.Position
  alias CcxtExtract.Normalization.ResponseEnvelopes
  alias CcxtExtract.Normalization.Ticker
  alias CcxtExtract.Normalization.Trade
  alias CcxtExtract.Normalization.Transaction

  @parser_types ~w(ticker trade ohlcv order position balance market transaction deposit_address)
  @initial_unresolved_reason "not_yet_derived"

  @typedoc "Per-method digest record; mirrors `MethodSignature` minus the AST body."
  @type digest_record :: %{
          required(String.t()) => term()
        }

  @typedoc "Stub field-map record. Same shape for `field_maps` and `response_envelopes`."
  @type stub_record :: %{
          required(String.t()) => nil | String.t() | map()
        }

  @doc """
  Build the full `normalization` block from per-exchange discovery entries.

  `parse_methods_entry` is the per-exchange entry from `parse_methods.json`
  (carries `parse_dispatch` and `parse_methods`). `fetch_methods_entry` is
  the per-exchange entry from `fetch_methods.json` (carries `fetch_methods`
  body ASTs). Either may be `nil` when the exchange has no override.

  Returns a map with three required keys: `parse_methods_digest`
  (compact, AST-free), `field_maps` (stub keyed by parser type),
  `response_envelopes` (real per-fetcher map, or stub when no parse_dispatch).
  """
  @spec build(map() | nil, map() | nil, keyword()) :: map()
  def build(parse_methods_entry, fetch_methods_entry, _opts \\ []) do
    %{
      "parse_methods_digest" => digest_from_entry(parse_methods_entry),
      "field_maps" => field_maps_record(parse_methods_entry),
      "response_envelopes" => response_envelopes_record(parse_methods_entry, fetch_methods_entry)
    }
  end

  @doc """
  Single-arg shim for callers (mostly tests + the v4 fallback in
  `Schema.build_exchange/4`) that don't carry a `fetch_methods_entry`.
  When `parse_methods_entry` carries `parse_dispatch`, response envelopes
  are still derived (per-fetcher entries flag `"no_fetcher_method_body"`);
  the scaffold `"not_yet_derived"` stub only applies when both args are `nil`.
  """
  @spec build(map() | nil) :: map()
  def build(parse_methods_entry), do: build(parse_methods_entry, nil)

  @spec response_envelopes_record(map() | nil, map() | nil) :: stub_record()
  defp response_envelopes_record(parse_methods_entry, fetch_methods_entry) do
    case ResponseEnvelopes.derive(parse_methods_entry, fetch_methods_entry) do
      nil -> stub_record()
      result -> Map.merge(stub_record(), result)
    end
  end

  @spec field_maps_record(map() | nil) :: stub_record()
  defp field_maps_record(parse_methods_entry) do
    stub_record()
    |> Map.put("balance", Balance.derive(parse_methods_entry))
    |> Map.put("deposit_address", DepositAddress.derive(parse_methods_entry))
    |> Map.put("market", Market.derive(parse_methods_entry))
    |> Map.put("ohlcv", OHLCV.derive(parse_methods_entry))
    |> Map.put("order", Order.derive(parse_methods_entry))
    |> Map.put("position", Position.derive(parse_methods_entry))
    |> Map.put("ticker", Ticker.derive(parse_methods_entry))
    |> Map.put("trade", Trade.derive(parse_methods_entry))
    |> Map.put("transaction", Transaction.derive(parse_methods_entry))
  end

  @doc """
  Returns the stub record used by both `field_maps` and
  `response_envelopes` — one nil-valued entry per parser type plus a
  closed-vocabulary `_unresolved_reason: "not_yet_derived"` tag.
  """
  @spec stub_record() :: stub_record()
  def stub_record do
    @parser_types
    |> Map.new(&{&1, nil})
    |> Map.put("_unresolved_reason", @initial_unresolved_reason)
  end

  @doc """
  The closed list of parser types scaffolded in `field_maps` /
  `response_envelopes`. Exposed for the contract invariant.
  """
  @spec parser_types() :: [String.t()]
  def parser_types, do: @parser_types

  @doc """
  Required keys at the `normalization` block level. Exposed for the
  contract invariant.
  """
  @spec required_keys() :: [String.t()]
  def required_keys, do: ["parse_methods_digest", "field_maps", "response_envelopes"]

  @doc """
  Required keys on every `parse_methods_digest` record — the four
  fields a consumer reads instead of walking the AST. Exposed for the
  contract invariant.
  """
  @spec digest_record_keys() :: [String.t()]
  def digest_record_keys, do: ["params", "return_type", "async", "statement_count"]

  @doc """
  Required keys on every `field_maps` / `response_envelopes` record —
  one per parser type plus the `_unresolved_reason` tag. Exposed for
  the contract invariant.
  """
  @spec stub_record_keys() :: [String.t()]
  def stub_record_keys, do: @parser_types ++ ["_unresolved_reason"]

  # --- Helpers ---

  @spec digest_from_entry(map() | nil) :: %{optional(String.t()) => map()}
  defp digest_from_entry(nil), do: %{}
  defp digest_from_entry(%{"parse_methods" => methods}) when is_map(methods), do: digest_from_methods(methods)
  defp digest_from_entry(_), do: %{}

  @spec digest_from_methods(map()) :: %{optional(String.t()) => map()}
  defp digest_from_methods(methods) do
    Map.new(methods, fn {name, ast} ->
      {name, digest_record(ast)}
    end)
  end

  @spec digest_record(term()) :: map()
  defp digest_record(ast) when is_map(ast) do
    %{
      "params" => normalize_params(Map.get(ast, "params")),
      "return_type" => Map.get(ast, "return_type"),
      "async" => Map.get(ast, "async", false) == true,
      "statement_count" => normalize_statement_count(Map.get(ast, "statements"))
    }
  end

  defp digest_record(_) do
    %{
      "params" => [],
      "return_type" => nil,
      "async" => false,
      "statement_count" => 0
    }
  end

  @spec normalize_params(term()) :: list()
  defp normalize_params(nil), do: []

  defp normalize_params(list) when is_list(list) do
    Enum.map(list, &normalize_param/1)
  end

  defp normalize_params(_), do: []

  @spec normalize_param(term()) :: %{required(String.t()) => term()}
  defp normalize_param(%{"name" => name} = param) when is_binary(name) do
    %{"name" => name, "type" => Map.get(param, "type")}
  end

  defp normalize_param(_), do: %{"name" => "", "type" => nil}

  @spec normalize_statement_count(term()) :: non_neg_integer()
  defp normalize_statement_count(n) when is_integer(n) and n >= 0, do: n
  defp normalize_statement_count(_), do: 0
end

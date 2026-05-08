defmodule CcxtExtract.TransactionClassification do
  @moduledoc """
  Per-unified-endpoint `transactional` / `on_chain` boolean flags.

  CCXT classifies endpoints as either off-chain (read-only market data,
  account state) or transactional (places orders, withdraws, transfers).
  Consumers need this flag to:

    * gate write operations behind explicit user confirmation in clients,
      and
    * decide whether to enforce two-factor / KMS signing.

  The flag is implicit in CCXT — derivable from the unified-method naming
  + verb conventions. This module crystallizes the convention into a
  per-endpoint boolean so consumers don't need to re-derive it.

  ## Definitions

    * `transactional` — the endpoint mutates exchange-side state. True for
      everything that places, edits, or cancels orders, withdraws,
      transfers, sets leverage / margin mode, opens / closes positions,
      borrows or repays. False for `fetch*` reads.
    * `on_chain` — strictly narrower than `transactional`. True only for
      endpoints that initiate a blockchain transaction the exchange will
      broadcast on the user's behalf — `withdraw*`. Internal exchange
      transfers (`transfer`) do NOT touch a chain and are NOT on-chain.

  Every on-chain endpoint is transactional; the inverse is not true.

  ## Source of truth

  CCXT's unified-method naming convention. Methods are read-only iff they
  start with `fetch`; everything else under the unified-method prefix set
  is transactional. The blockchain-touching subset is identified by the
  `withdraw` prefix.

  Some exchange-specific methods bypass the convention.
  TODO: This module currently derives strictly from the name; downstream
  method-body inspection (Phase 9 / overrides) can promote individual
  endpoints if needed.

  ## Security gap — non-unified raw broadcast endpoints

  The name-only classifier covers CCXT's **unified** method namespace.
  It does NOT see non-unified raw broadcast endpoints — DEX flows that
  expose blockchain transactions through helpers like `signL1Action` /
  `signEIP712`, or implicit-API paths like `public_post_sendtx` /
  `sendTxBatch`. Those endpoints are not unified-method keys, so they
  will not appear in `transaction_classification` at all.

  **Consumers MUST NOT treat `on_chain == false` (or absence from the
  map) as a sufficient safety gate for blockchain-broadcast operations.**
  Layer additional checks for raw / implicit-API endpoints, or wait for
  Phase 9 method-body inspection / overrides to extend coverage.

  Tracked as a follow-up roadmap item — see ROADMAP.md.

  ## Usage

      iex> CcxtExtract.TransactionClassification.derive(%{
      ...>   "fetchTicker" => ["publicGetTicker"],
      ...>   "createOrder" => ["privatePostOrder"],
      ...>   "withdraw" => ["privatePostWithdraw"]
      ...> })
      %{
        "createOrder" => %{"transactional" => true, "on_chain" => false},
        "fetchTicker" => %{"transactional" => false, "on_chain" => false},
        "withdraw" => %{"transactional" => true, "on_chain" => true}
      }

  Returns `nil` when the input is `nil` (no unified endpoints extracted)
  or an empty map (nothing to classify).
  """

  # Fetch-prefixed methods are read-only by convention. Anything else
  # under the unified-method prefix family in `CcxtExtract.UnifiedEndpoints`
  # mutates state.
  @read_prefix "fetch"

  # Methods that initiate a blockchain transaction. CCXT's withdraw family
  # (`withdraw`, `withdrawAll`, `withdrawCrypto`) all push value onto a
  # chain; `transfer` is exchange-internal and stays off-chain.
  @on_chain_prefix "withdraw"

  @doc """
  Classify each unified endpoint name.

  Accepts the same shape as `structure.unified_endpoints` —
  `%{name => [interface_method_names]}` — but ignores the values; only
  the keys are inspected. Returns a map keyed by the same names with
  `%{"transactional" => bool, "on_chain" => bool}` values.

  Returns `nil` for `nil` input or an empty map (no endpoints to
  classify), matching the rest of the per-exchange schema's
  "null when nothing to say" idiom.
  """
  @spec derive(map() | nil) :: %{optional(String.t()) => %{String.t() => boolean()}} | nil
  def derive(nil), do: nil

  def derive(unified_endpoints) when is_map(unified_endpoints) do
    if map_size(unified_endpoints) == 0 do
      nil
    else
      Map.new(unified_endpoints, fn {name, _calls} -> {name, classify(name)} end)
    end
  end

  @doc """
  Classify a single unified-endpoint name.

  Convention-only:

    * `transactional?` — true unless the name starts with `fetch`.
    * `on_chain?` — true iff the name starts with `withdraw`.
  """
  @spec classify(String.t()) :: %{String.t() => boolean()}
  def classify(name) when is_binary(name) do
    %{"transactional" => transactional?(name), "on_chain" => on_chain?(name)}
  end

  @doc """
  True iff the unified-endpoint name represents a write operation.
  """
  @spec transactional?(String.t()) :: boolean()
  def transactional?(name) when is_binary(name) do
    not String.starts_with?(name, @read_prefix)
  end

  @doc """
  True iff the unified-endpoint name initiates a blockchain transaction
  the exchange broadcasts on the user's behalf.
  """
  @spec on_chain?(String.t()) :: boolean()
  def on_chain?(name) when is_binary(name) do
    String.starts_with?(name, @on_chain_prefix)
  end
end

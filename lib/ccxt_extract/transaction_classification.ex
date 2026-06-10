defmodule CcxtExtract.TransactionClassification do
  @moduledoc """
  Per-endpoint `transactional` / `on_chain` boolean flags.

  CCXT classifies endpoints as either off-chain (read-only market data,
  account state) or transactional (places orders, withdraws, transfers).
  Consumers need this flag to:

    * gate write operations behind explicit user confirmation in clients,
      and
    * decide whether to enforce two-factor / KMS signing.

  ## Definitions

    * `transactional` — the endpoint mutates exchange-side state. True for
      everything that places, edits, or cancels orders, withdraws,
      transfers, sets leverage / margin mode, opens / closes positions,
      borrows or repays. False for `fetch*` reads.
    * `on_chain` — strictly narrower than `transactional`. True for
      endpoints that initiate a blockchain transaction the exchange will
      broadcast on the user's behalf.

  Every on-chain endpoint is transactional; the inverse is not true.

  ## Two derivation layers

  1. **Name-only base (Task 73d).** CCXT's unified-method naming
     convention. Methods are read-only iff they start with `fetch`;
     everything else under the unified-method prefix set is transactional.
     The blockchain-touching subset is the `withdraw*` prefix.

  2. **Raw-broadcast promotion (Task 73f).** The name-only base cannot see
     non-unified raw broadcast endpoints — DEX flows that sign and
     broadcast a blockchain transaction through helpers like `signL1Action`
     / `signUserSignedAction` (hyperliquid), `starknetSign` (paradex), or
     `createSignedRequest` / EIP-712 typed-data builders (grvt), and
     implicit-API paths like `sendTx` / `sendTxBatch` (lighter). An OXC pass
     (`CcxtExtract.RawBroadcast`) detects the write-side methods that reach
     such a helper; `derive/3` promotes each into the map with
     `on_chain: true` **and** `transactional: true`. Implicit-API
     `sendTx`-family endpoints are detected from `describe().api` and added
     the same way (key = the CCXT implicit method name, e.g.
     `publicPostSendTx`).

  Because every detected broadcast endpoint is promoted to `on_chain: true`,
  a consumer **can** treat `on_chain == false` (or absence from the map) as
  a negative safety gate within the corpus's detection coverage. The
  `transaction_classification_promoted_flags_consistent` contract-test
  invariant guards that no entry carries `on_chain: true` without
  `transactional: true`.

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

  Returns `nil` when there is nothing to classify (no unified endpoints and
  no detected broadcast promotions).
  """

  # Fetch-prefixed methods are read-only by convention. Anything else
  # under the unified-method prefix family in `CcxtExtract.UnifiedEndpoints`
  # mutates state.
  @read_prefix "fetch"

  # Methods that initiate a blockchain transaction. CCXT's withdraw family
  # (`withdraw`, `withdrawAll`, `withdrawCrypto`) all push value onto a
  # chain; `transfer` is exchange-internal and stays off-chain by name.
  @on_chain_prefix "withdraw"

  # An entry flagged on-chain by the raw-broadcast pass or by an implicit
  # `sendTx` endpoint. On-chain implies transactional.
  @promoted %{"transactional" => true, "on_chain" => true}

  @doc """
  Classify each endpoint name, then promote detected raw broadcast endpoints.

  ## Parameters

    * `unified_endpoints` — the `structure.unified_endpoints` shape
      (`%{name => [interface_method_names]}`); only the keys are inspected
      for the name-only base.
    * `raw_broadcast` — the per-exchange `raw_broadcast.json` entry (or
      `nil`). Its `"broadcast_methods"` keys are promoted to `on_chain` +
      `transactional`.
    * `describe_api` — the resolved `describe().api` map (or `nil`).
      Scanned for `sendTx` / `sendTxBatch` implicit-API endpoints, which are
      promoted under their CCXT implicit method name.

  Returns a map keyed by endpoint name with
  `%{"transactional" => bool, "on_chain" => bool}` values, or `nil` when
  there is nothing to classify.
  """
  @spec derive(map() | nil, map() | nil, map() | nil) ::
          %{optional(String.t()) => %{String.t() => boolean()}} | nil
  def derive(unified_endpoints, raw_broadcast \\ nil, describe_api \\ nil) do
    base = base_classification(unified_endpoints)

    promotions =
      raw_broadcast
      |> broadcast_promotions()
      |> Map.merge(sendtx_promotions(describe_api))

    merged = Map.merge(base, promotions)

    if map_size(merged) == 0, do: nil, else: merged
  end

  @doc """
  Classify a single endpoint name from the naming convention only.

    * `transactional?` — true unless the name starts with `fetch`.
    * `on_chain?` — true iff the name starts with `withdraw`.
  """
  @spec classify(String.t()) :: %{String.t() => boolean()}
  def classify(name) when is_binary(name) do
    %{"transactional" => transactional?(name), "on_chain" => on_chain?(name)}
  end

  @doc """
  True iff the endpoint name represents a write operation (not a `fetch*`
  read). The single source of truth for the read/write naming convention —
  also consumed by `CcxtExtract.RawBroadcast` to drop authenticating reads.
  """
  @spec transactional?(String.t()) :: boolean()
  def transactional?(name) when is_binary(name) do
    not String.starts_with?(name, @read_prefix)
  end

  @doc """
  True iff the endpoint name initiates a blockchain transaction by the
  `withdraw*` naming convention. Note this is the name-only signal; the
  raw-broadcast pass promotes additional on-chain endpoints in `derive/3`.
  """
  @spec on_chain?(String.t()) :: boolean()
  def on_chain?(name) when is_binary(name) do
    String.starts_with?(name, @on_chain_prefix)
  end

  # --- Base (name-only) classification ---

  defp base_classification(unified_endpoints) when is_map(unified_endpoints) do
    Map.new(unified_endpoints, fn {name, _calls} -> {name, classify(name)} end)
  end

  defp base_classification(_), do: %{}

  # --- Raw broadcast promotions ---

  defp broadcast_promotions(%{"broadcast_methods" => methods}) when is_map(methods) do
    Map.new(Map.keys(methods), &{&1, @promoted})
  end

  defp broadcast_promotions(_), do: %{}

  # --- Implicit-API sendTx promotions ---

  # Walk describe().api collecting the key path to every scalar leaf whose
  # final segment matches the sendTx family; promote each under the CCXT
  # implicit method name built from the full key path.
  defp sendtx_promotions(api) when is_map(api) do
    api
    |> collect_sendtx_paths([])
    |> Map.new(&{implicit_method_name(&1), @promoted})
  end

  defp sendtx_promotions(_), do: %{}

  defp collect_sendtx_paths(node, prefix) when is_map(node) do
    Enum.flat_map(node, fn
      {key, child} when is_map(child) or is_list(child) ->
        collect_sendtx_paths(child, prefix ++ [key])

      {key, _leaf} when is_binary(key) ->
        if sendtx_path?(key), do: [prefix ++ [key]], else: []

      _ ->
        []
    end)
  end

  # Array form: `api: %{public: %{post: ["sendTx", "sendTxBatch"]}}`. Each
  # string element is an endpoint path under the accumulated prefix.
  defp collect_sendtx_paths(node, prefix) when is_list(node) do
    for path <- node, is_binary(path), sendtx_path?(path), do: prefix ++ [path]
  end

  defp collect_sendtx_paths(_node, _prefix), do: []

  defp sendtx_path?(key) when is_binary(key), do: key |> String.downcase() |> String.starts_with?("sendtx")

  # CCXT implicit method name = camelCase join of the api key path, e.g.
  # ["public", "post", "sendTx"] -> "publicPostSendTx".
  defp implicit_method_name([first | rest]) do
    Enum.join([first | Enum.map(rest, &capitalize_first/1)])
  end

  defp implicit_method_name([]), do: ""

  defp capitalize_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp capitalize_first(""), do: ""
end

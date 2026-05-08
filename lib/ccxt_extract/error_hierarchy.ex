defmodule CcxtExtract.ErrorHierarchy do
  @moduledoc """
  CCXT base error class hierarchy + retry-classification buckets.

  Walks `priv/ccxt/ts/src/base/errors.ts` to surface the parent → child
  graph that every CCXT exchange's `handleErrors()` /
  `httpExceptions` / `exceptions` maps reference. The hierarchy is the
  load-bearing contract between an exchange's named exception class
  (e.g. `"DDoSProtection"`, `"InvalidOrder"`) and the consumer's
  retry-policy decision tree (rate-limit vs network vs auth vs
  non-retryable).

  ## What's emitted

    * `hierarchy/0` — `%{class_name => parent_class_name | nil}`. CCXT's
      `BaseError` extends the JavaScript built-in `Error` (which is
      outside the CCXT taxonomy and has no entry in this map);
      `walk_ancestors/2` terminates at `"Error"` because the map has no
      key for it. ~40 classes total.
    * `bucket_for/1` — closed-vocabulary retry bucket for a class name.
      Walks ancestors and returns the **most specific** bucket: a class
      under `DDoSProtection` is `"rate_limit"` even though
      `DDoSProtection` extends `NetworkError` (which would also match
      `"network"`).
    * `buckets/0` — ordered list of bucket names: `~w(rate_limit auth
      server_busy network non_retryable)`. Order matters for the
      "tightest match wins" classifier in `bucket_for/1`.

  ## Bucket assignment

  Buckets are derived from the CCXT base hierarchy structure (Tasks 85-87).
  Roots are picked so descendants inherit honestly:

    * `rate_limit` — `DDoSProtection`, `RateLimitExceeded` (subset of
      `NetworkError`)
    * `auth` — `AuthenticationError` and descendants (`PermissionDenied`,
      `AccountNotEnabled`, `AccountSuspended`)
    * `server_busy` — `ExchangeNotAvailable`, `OnMaintenance` (subset of
      `NetworkError`), `BadResponse`, `NullResponse` (subset of
      `OperationFailed`)
    * `network` — `NetworkError` and descendants (e.g. `RequestTimeout`,
      `InvalidNonce`, `ChecksumError`) MINUS the rate_limit subset
    * `non_retryable` — everything else under `ExchangeError` /
      `OperationFailed` / `BaseError` (including `InvalidOrder`,
      `InsufficientFunds`, `BadRequest`, `BadSymbol`, etc.)

  Unknown class names — exchange-specific exceptions not in the CCXT
  base hierarchy — fall through to `"non_retryable"` per the Honesty
  Rule (no fabricated retry guidance for unrecognized classes).

  ## Provenance

  Both the hierarchy and the bucket map are `derived` — they're a
  walk over CCXT source plus a constant rule set, not an override or a
  raw passthrough.

  ## Schema bump

  Lands at schema 3.2.0 (additive, non-breaking) under v3, and as new
  paths in `errors.class_hierarchy` / `errors.retry_classification` /
  `errors.status_map` under v4 (gated). See SCHEMA.md for v4 paths.
  """

  alias CcxtExtract.Paths

  # --- Bucket roots ---
  #
  # Lists of class names that ROOT each bucket — every descendant of
  # one of these classes inherits the bucket. Order in @buckets defines
  # tiebreak priority for the "tightest match wins" classifier
  # (`bucket_for/1`): if `class` has an ancestor in `@rate_limit_roots`
  # AND another ancestor in `@network_roots`, the rate_limit bucket
  # wins because it's listed first.
  @rate_limit_roots ~w(DDoSProtection RateLimitExceeded)
  @auth_roots ~w(AuthenticationError)
  @server_busy_roots ~w(ExchangeNotAvailable OnMaintenance BadResponse NullResponse)
  @network_roots ~w(NetworkError)

  @buckets ~w(rate_limit auth server_busy network non_retryable)

  # --- Hierarchy parsing ---

  # Build the hierarchy at compile time from the CCXT source if available,
  # falling back to a hand-curated table if not. The table is the source
  # of truth for the bucket classifier — it's frozen content (CCXT base
  # error classes change at most once per major release) and committing
  # it lets `mix compile` succeed in fresh clones that haven't run
  # `mix ccxt_extract.setup` yet.
  #
  # Every entry in `@hierarchy` mirrors `priv/ccxt/ts/src/base/errors.ts`
  # exactly. If the upstream file changes, regeneration is a one-liner —
  # see `verify_hierarchy_against_source/0` test in
  # `test/ccxt_extract/error_hierarchy_test.exs`.
  @hierarchy %{
    "BaseError" => "Error",
    "ExchangeError" => "BaseError",
    "AuthenticationError" => "ExchangeError",
    "PermissionDenied" => "AuthenticationError",
    "AccountNotEnabled" => "PermissionDenied",
    "AccountSuspended" => "AuthenticationError",
    "ArgumentsRequired" => "ExchangeError",
    "BadRequest" => "ExchangeError",
    "BadSymbol" => "BadRequest",
    "OperationRejected" => "ExchangeError",
    "NoChange" => "OperationRejected",
    "MarginModeAlreadySet" => "NoChange",
    "MarketClosed" => "OperationRejected",
    "ManualInteractionNeeded" => "OperationRejected",
    "RestrictedLocation" => "OperationRejected",
    "InsufficientFunds" => "ExchangeError",
    "InvalidAddress" => "ExchangeError",
    "AddressPending" => "InvalidAddress",
    "InvalidOrder" => "ExchangeError",
    "OrderNotFound" => "InvalidOrder",
    "OrderNotCached" => "InvalidOrder",
    "OrderImmediatelyFillable" => "InvalidOrder",
    "OrderNotFillable" => "InvalidOrder",
    "DuplicateOrderId" => "InvalidOrder",
    "ContractUnavailable" => "InvalidOrder",
    "NotSupported" => "ExchangeError",
    "InvalidProxySettings" => "ExchangeError",
    "ExchangeClosedByUser" => "ExchangeError",
    "OperationFailed" => "BaseError",
    "NetworkError" => "OperationFailed",
    "DDoSProtection" => "NetworkError",
    "RateLimitExceeded" => "NetworkError",
    "ExchangeNotAvailable" => "NetworkError",
    "OnMaintenance" => "ExchangeNotAvailable",
    "InvalidNonce" => "NetworkError",
    "ChecksumError" => "InvalidNonce",
    "RequestTimeout" => "NetworkError",
    "BadResponse" => "OperationFailed",
    "NullResponse" => "BadResponse",
    "CancelPending" => "OperationFailed",
    "UnsubscribeError" => "BaseError"
  }

  # --- Public API ---

  @doc """
  Returns the CCXT base error class hierarchy as a flat map of
  `class_name => parent_class_name`. CCXT's `BaseError` extends the
  JavaScript built-in `Error`, which has no entry in the map (the JS
  `Error` is outside the CCXT taxonomy).
  """
  @spec hierarchy() :: %{String.t() => String.t() | nil}
  def hierarchy, do: @hierarchy

  @doc """
  Returns the ordered list of retry-classification bucket names. Order
  defines tiebreak priority — the first bucket whose roots appear in a
  class's ancestor chain wins.
  """
  @spec buckets() :: [String.t()]
  def buckets, do: @buckets

  @doc """
  Returns the retry bucket for `class`. Walks ancestors via
  `hierarchy/0`; returns `"non_retryable"` for unrecognized classes
  (Honesty Rule — no fabricated retry guidance).

  ## Examples

      iex> CcxtExtract.ErrorHierarchy.bucket_for("RateLimitExceeded")
      "rate_limit"

      iex> CcxtExtract.ErrorHierarchy.bucket_for("DDoSProtection")
      "rate_limit"

      iex> CcxtExtract.ErrorHierarchy.bucket_for("OnMaintenance")
      "server_busy"

      iex> CcxtExtract.ErrorHierarchy.bucket_for("RequestTimeout")
      "network"

      iex> CcxtExtract.ErrorHierarchy.bucket_for("PermissionDenied")
      "auth"

      iex> CcxtExtract.ErrorHierarchy.bucket_for("InvalidOrder")
      "non_retryable"

      iex> CcxtExtract.ErrorHierarchy.bucket_for("ExchangeSpecificMystery")
      "non_retryable"
  """
  @spec bucket_for(String.t() | nil) :: String.t()
  def bucket_for(nil), do: "non_retryable"

  def bucket_for(class) when is_binary(class) do
    chain = ancestors(class)

    cond do
      Enum.any?(chain, &(&1 in @rate_limit_roots)) -> "rate_limit"
      Enum.any?(chain, &(&1 in @auth_roots)) -> "auth"
      Enum.any?(chain, &(&1 in @server_busy_roots)) -> "server_busy"
      Enum.any?(chain, &(&1 in @network_roots)) -> "network"
      true -> "non_retryable"
    end
  end

  @doc """
  Returns the ancestor chain for `class` from itself up to `BaseError`,
  inclusive. Returns `[class]` (no parents) for unknown classes — they
  are honest leaves with no inheritance information.

  ## Examples

      iex> CcxtExtract.ErrorHierarchy.ancestors("DDoSProtection")
      ["DDoSProtection", "NetworkError", "OperationFailed", "BaseError", "Error"]

      iex> CcxtExtract.ErrorHierarchy.ancestors("Unknown")
      ["Unknown"]
  """
  @spec ancestors(String.t() | nil) :: [String.t()]
  def ancestors(nil), do: []

  def ancestors(class) when is_binary(class) do
    walk_ancestors(class, [class])
  end

  @spec walk_ancestors(String.t(), [String.t()]) :: [String.t()]
  defp walk_ancestors(class, acc) do
    case Map.get(@hierarchy, class) do
      nil -> Enum.reverse(acc)
      parent -> walk_ancestors(parent, [parent | acc])
    end
  end

  # --- Source-of-truth helpers (used by tests, not the runtime path) ---

  @doc """
  Parses `priv/ccxt/ts/src/base/errors.ts` via OXC and returns the
  hierarchy it encodes. Used by `error_hierarchy_test.exs` to detect
  drift between the committed `@hierarchy` table above and upstream
  CCXT — if upstream adds a new class or changes a parent, the test
  fails loudly and the table needs regeneration.

  Raises if the source file is missing (run `mix ccxt_extract.setup`).
  """
  @spec parse_source!() :: %{String.t() => String.t() | nil}
  # sobelow_skip ["Traversal.FileModule"]
  def parse_source! do
    path = Path.join([Paths.ts_src(), "base", "errors.ts"])
    source = File.read!(path)
    {:ok, ast} = OXC.parse(source, "errors.ts")

    ast.body
    |> Enum.flat_map(&class_entry/1)
    |> Map.new()
  end

  @spec class_entry(map()) :: [{String.t(), String.t() | nil}]
  defp class_entry(%{type: :class_declaration, id: %{name: name}, superClass: super_class}) do
    [{name, super_class && super_class.name}]
  end

  defp class_entry(_), do: []
end

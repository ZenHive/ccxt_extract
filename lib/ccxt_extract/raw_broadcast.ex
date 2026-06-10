defmodule CcxtExtract.RawBroadcast do
  @moduledoc """
  Detect non-unified raw blockchain-broadcast endpoints via an OXC pass.

  Task 73d's name-only classifier (`CcxtExtract.TransactionClassification`)
  covers CCXT's **unified** method namespace. It cannot see DEX flows that
  expose blockchain transactions through helpers like `signL1Action` /
  `signUserSignedAction` (hyperliquid), `starknetSign` (paradex), or
  `createSignedRequest` / EIP-712 typed-data builders (grvt) — those methods
  broadcast on-chain but the name-only convention reads them as off-chain.

  This module is the OXC counterpart: it parses each exchange's TypeScript
  source, scans **every method body** (the `sign()` method and every
  exchange method alike), and emits, per exchange:

    * `signing_imports` — DEX signing-library imports detected at the file
      level (`noble-curves`, `ethers`, `starknet`). A corroborating signal
      that the exchange does its own on-chain signing.
    * `eip712_builder` — whether any method body invokes an EIP-712
      typed-data builder (`ethEncodeStructuredData` / `hashTypedData`).
    * `broadcast_methods` — map of `method_name => [helpers]` for every
      **async, write-side** method that (transitively) reaches a known
      signed-payload broadcast helper. Two gates apply:

        * **async** — in CCXT, public/implicit API endpoints are `async`,
          while signing primitives and payload builders (`signL1Action`,
          `buildWithdrawSig`, …) are synchronous. Gating on `async`
          promotes the real endpoints and drops the primitives; transitive
          closure still credits an endpoint that signs through an
          intermediate `build*Sig` helper.
        * **write-side** (`TransactionClassification.transactional?/1`,
          i.e. not `fetch*`) — a `fetch*` read that signs is *authenticating*
          (e.g. paradex signs a starknet challenge to read private state),
          not broadcasting a transaction. Excluding reads keeps the
          on-chain promotion to genuine write flows.

  `CcxtExtract.TransactionClassification.derive/3` consumes
  `broadcast_methods` and promotes each detected endpoint into
  `transaction_classification` with `on_chain: true` and
  `transactional: true`. Exchanges with no detected signal are skipped (not
  emitted) so the discovery file stays compact.

  ## Usage

      {:ok, exchanges, stats} = CcxtExtract.RawBroadcast.extract()
      CcxtExtract.RawBroadcast.write!(exchanges)
  """

  use CcxtExtract.OXCExtractor, output_file: "raw_broadcast.json"

  # Signed-payload broadcast helpers. A method whose body (transitively)
  # calls one of these constructs a signed blockchain payload the exchange
  # broadcasts on the user's behalf. Curated, cross-exchange-meaningful
  # names — NOT generic primitives (`signMessage`, `hash`) which auth flows
  # also use without broadcasting.
  @broadcast_helpers ~w(signL1Action signUserSignedAction signEIP712 starknetSign createSignedRequest)

  # EIP-712 typed-data builders. Their presence is recorded as a
  # corroborating signal; they are primitives (called by the broadcast
  # helpers above), not endpoint markers themselves.
  @eip712_builders ~w(ethEncodeStructuredData hashTypedData)

  # Substring markers in an import source path -> canonical signing-library
  # name. `noble-curves` (secp256k1) is the signing lib; `noble-hashes`
  # (keccak) is hashing and intentionally excluded.
  @signing_lib_markers [
    {"noble-curves", "noble-curves"},
    {"ethers", "ethers"},
    {"starknet", "starknet"}
  ]

  @impl true
  @spec source_dir() :: String.t()
  def source_dir, do: CcxtExtract.Paths.ts_src()

  @impl true
  @spec extract_from_ast(map(), String.t()) :: map() | nil
  def extract_from_ast(ast, filename) do
    export = Enum.find(ast.body, &(&1.type == :export_default_declaration))

    if export && export.declaration && Map.get(export.declaration, :body) do
      build_entry(ast, export.declaration, filename)
    end
  end

  @impl true
  @spec write_stats([map()]) :: map()
  def write_stats(exchanges) do
    %{"with_broadcast" => Enum.count(exchanges, &(map_size(&1["broadcast_methods"]) > 0))}
  end

  # --- Extraction ---

  defp build_entry(ast, class, filename) do
    class_name = if class.id, do: class.id.name
    id = class_name || Path.rootname(filename)

    signing_imports = signing_imports(ast)
    method_facts = method_facts(class)
    broadcast_methods = broadcast_methods(method_facts)
    eip712_builder? = Enum.any?(method_facts, & &1.eip712?)

    if signing_imports == [] and broadcast_methods == %{} and not eip712_builder? do
      nil
    else
      %{
        "id" => id,
        "class_name" => class_name,
        "file" => filename,
        "signing_imports" => signing_imports,
        "eip712_builder" => eip712_builder?,
        "broadcast_methods" => broadcast_methods
      }
    end
  end

  # Collect DEX signing-library imports from the file's import declarations.
  defp signing_imports(ast) do
    ast.body
    |> Enum.filter(&(&1.type == :import_declaration))
    |> Enum.flat_map(fn decl ->
      source = get_in(decl, [Access.key(:source), Access.key(:value)]) || ""
      for {marker, name} <- @signing_lib_markers, String.contains?(source, marker), do: name
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Per-method facts: name, async flag, the set of `this.<x>()` calls in the
  # body, the curated broadcast helpers called directly, and whether an
  # EIP-712 builder is invoked.
  defp method_facts(class) do
    class.body.body
    |> Enum.filter(&(&1.type == :method_definition))
    |> Enum.flat_map(&method_fact/1)
  end

  defp method_fact(%{key: %{name: name}, value: value}) when is_binary(name) do
    body = Map.get(value, :body)
    calls = body |> this_call_names() |> MapSet.new()

    [
      %{
        name: name,
        async: value.async == true,
        calls: calls,
        direct: MapSet.intersection(calls, MapSet.new(@broadcast_helpers)),
        eip712?: not MapSet.disjoint?(calls, MapSet.new(@eip712_builders))
      }
    ]
  end

  defp method_fact(_), do: []

  # Async, write-side methods that transitively reach a broadcast helper,
  # mapped to the sorted list of helpers reached. `fetch*` reads are dropped:
  # signing inside a read is authentication, not a transaction broadcast.
  defp broadcast_methods(facts) do
    reaches = transitive_reaches(facts)

    endpoint_names =
      for f <- facts,
          f.async,
          CcxtExtract.TransactionClassification.transactional?(f.name),
          into: MapSet.new(),
          do: f.name

    for {name, helpers} <- reaches,
        MapSet.member?(endpoint_names, name),
        MapSet.size(helpers) > 0,
        into: %{} do
      {name, helpers |> MapSet.to_list() |> Enum.sort()}
    end
  end

  # Fixpoint: reaches[name] = direct[name] ∪ ⋃ reaches[c] for each in-class
  # `this.c()` callee. Iterates until no set grows.
  defp transitive_reaches(facts) do
    names = MapSet.new(facts, & &1.name)
    direct = Map.new(facts, &{&1.name, &1.direct})
    calls = Map.new(facts, &{&1.name, MapSet.intersection(&1.calls, names)})

    fixpoint(direct, calls, direct)
  end

  defp fixpoint(direct, calls, current) do
    next =
      Map.new(current, fn {name, _} ->
        reached =
          calls
          |> Map.fetch!(name)
          |> Enum.reduce(Map.fetch!(direct, name), fn callee, acc ->
            MapSet.union(acc, Map.get(current, callee, MapSet.new()))
          end)

        {name, reached}
      end)

    if next == current, do: next, else: fixpoint(direct, calls, next)
  end

  # --- AST traversal ---

  # Collect the names of every `this.<name>(...)` call reachable from node.
  defp this_call_names(node) when is_map(node) do
    own =
      case node do
        %{
          type: :call_expression,
          callee: %{
            type: :member_expression,
            object: %{type: :this_expression},
            property: %{type: :identifier, name: name}
          }
        }
        when is_binary(name) ->
          [name]

        _ ->
          []
      end

    own ++ (node |> Map.values() |> Enum.flat_map(&this_call_names/1))
  end

  defp this_call_names(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &this_call_names/1)
  defp this_call_names(_), do: []
end

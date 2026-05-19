defmodule Mix.Tasks.CcxtExtract.Methods do
  @shortdoc "Extract method inventory from CCXT TypeScript source"

  @moduledoc """
  Parses CCXT TypeScript exchange files with OXC and extracts per-method
  metadata: name, async status, parameter names with TS types, return type,
  and statement count.

  Writes output to `priv/discoveries/methods_rest.json` and/or
  `priv/discoveries/methods_ws.json`.

      mix ccxt_extract.methods              # both REST and WS
      mix ccxt_extract.methods --type rest  # REST only
      mix ccxt_extract.methods --type ws    # WS only
      mix ccxt_extract.methods --tier1 --dex
      mix ccxt_extract.methods --exchange binance,deribit

  ## Options

    * `--type rest|ws` — restrict to one output file (default: both).
    * `--tier1 --tier2 --tier3 --dex` — restrict extraction to the named
      priority tiers (combinable). Scoped runs merge into the existing
      aggregate; out-of-scope entries are preserved.
    * `--exchange ID` — restrict to explicit exchange IDs. Typos fail
      loudly with fuzzy suggestions.
    * `--all` — explicit full-universe run; conflicts with any narrowing flag.

  The active scope is stamped into the JSON envelope(s) as `tier_scope`.
  """

  use Mix.Task

  alias CcxtExtract.TaskScope

  @impl true
  def run(args) do
    {scope, tier_scope, opts} = TaskScope.parse_and_resolve!(args, type: :string)

    types =
      case Keyword.get(opts, :type) do
        "rest" -> [:rest]
        "ws" -> [:ws]
        nil -> [:rest, :ws]
        other -> Mix.raise(~s(Invalid --type #{inspect(other)}. Must be "rest" or "ws".))
      end

    for type <- types do
      extract_and_write(type, scope, tier_scope)
    end
  end

  defp extract_and_write(type, scope, tier_scope) do
    label = String.upcase(to_string(type))
    Mix.shell().info("Extracting #{label} method inventory from CCXT TypeScript source...")

    {:ok, all_exchanges, stats} = CcxtExtract.Methods.extract(type)
    exchanges = TaskScope.filter_entries(all_exchanges, scope, "id")

    total_methods = exchanges |> Enum.map(& &1["method_count"]) |> Enum.sum()

    async_count =
      exchanges
      |> Enum.flat_map(& &1["methods"])
      |> Enum.count(& &1["async"])

    CcxtExtract.Methods.write!(type, exchanges, scope: scope, tier_scope: tier_scope)

    error_msg =
      if stats.errors == [] do
        ""
      else
        "\n  Parse errors: #{length(stats.errors)} (check logs for details)"
      end

    Mix.shell().info("""
    Done. #{length(exchanges)} #{label} exchanges extracted.
      Total methods: #{total_methods} (#{async_count} async)
      Skipped (no class): #{length(stats.skipped)}#{error_msg}
    Output: priv/discoveries/methods_#{String.downcase(label)}.json
    """)
  end
end

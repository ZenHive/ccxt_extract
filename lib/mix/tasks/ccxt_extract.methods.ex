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
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, leftover, invalid} = OptionParser.parse(args, strict: [type: :string])

    if invalid != [] do
      switches = Enum.map_join(invalid, ", ", fn {k, _} -> k end)
      Mix.raise("Unknown option(s): #{switches}. Only --type is supported.")
    end

    if leftover != [] do
      Mix.raise("Unexpected argument(s): #{Enum.join(leftover, ", ")}. This task takes no positional arguments.")
    end

    types =
      case opts[:type] do
        "rest" -> [:rest]
        "ws" -> [:ws]
        nil -> [:rest, :ws]
        other -> Mix.raise(~s(Invalid --type #{inspect(other)}. Must be "rest" or "ws".))
      end

    for type <- types do
      extract_and_write(type)
    end
  end

  defp extract_and_write(type) do
    label = String.upcase(to_string(type))
    Mix.shell().info("Extracting #{label} method inventory from CCXT TypeScript source...")

    {:ok, exchanges, stats} = CcxtExtract.Methods.extract(type)

    total_methods = exchanges |> Enum.map(& &1["method_count"]) |> Enum.sum()

    async_count =
      exchanges
      |> Enum.flat_map(& &1["methods"])
      |> Enum.count(& &1["async"])

    CcxtExtract.Methods.write!(type, exchanges)

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

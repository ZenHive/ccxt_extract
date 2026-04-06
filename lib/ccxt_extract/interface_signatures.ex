defmodule CcxtExtract.InterfaceSignatures do
  @moduledoc """
  Extract interface method signatures from CCXT abstract TypeScript files.

  Abstract files (`priv/ccxt/ts/src/abstract/*.ts`) contain per-exchange
  TypeScript interface declarations with typed API method signatures. These
  define the generated endpoint methods each exchange supports (e.g.,
  `publicGetTicker`, `privatePostOrder`).

  Each signature has a name, parameters (with types), and return type — but
  no method body (unlike MethodAST from parse_methods/ws_methods).

  Reuses parameter and type extraction from `CcxtExtract.Methods`.

  ## Usage

      {:ok, exchanges, stats} = CcxtExtract.InterfaceSignatures.extract()
      CcxtExtract.InterfaceSignatures.write!(exchanges)
  """

  use CcxtExtract.OXCExtractor, output_file: "interface_signatures.json"

  @impl true
  def source_dir, do: Path.join(CcxtExtract.Paths.ts_src(), "abstract")

  @impl true
  def extract_from_ast(ast, filename) do
    iface = find_exchange_interface(ast.body)

    if iface do
      id = Path.rootname(filename)

      signatures_map =
        iface.body.body
        |> Enum.filter(&(&1.type == "TSMethodSignature"))
        |> Map.new(&{&1.key.name, extract_signature(&1)})

      %{
        "id" => id,
        "class_name" => id,
        "file" => filename,
        "interface_name" => iface.id.name,
        "interface_signature_count" => map_size(signatures_map),
        "interface_signatures" => signatures_map
      }
    end
  end

  @impl true
  def write_stats(exchanges) do
    %{
      "with_signatures" => Enum.count(exchanges, fn e -> e["interface_signature_count"] > 0 end),
      "total_signatures" => Enum.sum(Enum.map(exchanges, & &1["interface_signature_count"]))
    }
  end

  @doc """
  Extract a single interface method signature from a TSMethodSignature node.

  Returns a map with name, params (with types), and return type.
  Unlike MethodAST, interface signatures have no body, async, or statements.
  """
  @spec extract_signature(map()) :: map()
  def extract_signature(member) do
    %{
      "name" => member.key.name,
      "params" => CcxtExtract.Methods.extract_params(member.params),
      "return_type" => CcxtExtract.Methods.extract_return_type(member)
    }
  end

  # Find the first TSInterfaceDeclaration in the top-level body.
  # Each abstract file has exactly one — named "Exchange" for primary exchanges,
  # or the parent name (e.g., "binance", "gate") for alias exchanges.
  defp find_exchange_interface(body) do
    Enum.find(body, &(&1.type == "TSInterfaceDeclaration"))
  end
end

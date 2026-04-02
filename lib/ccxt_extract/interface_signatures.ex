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

  require Logger

  @output_file "interface_signatures.json"

  @doc """
  Extract interface signatures from all abstract TypeScript files.

  Parses each `.ts` file in `priv/ccxt/ts/src/abstract/` via OXC, finds the
  interface declaration, and extracts all method signatures.

  Returns `{:ok, exchanges, stats}` where stats has `:skipped` and `:errors` lists.
  """
  @spec extract() :: {:ok, [map()], map()}
  def extract do
    abstract_dir = abstract_src()

    if !File.dir?(abstract_dir) do
      raise "CCXT abstract source not found at #{abstract_dir}. Run `mix ccxt_extract.setup` first."
    end

    files = Path.wildcard(Path.join(abstract_dir, "*.ts"))

    if files == [] do
      raise "No .ts files found in #{abstract_dir}. CCXT source may be incomplete."
    end

    {exchanges, skipped, errors} =
      files
      |> Enum.map(&parse_file/1)
      |> Enum.reduce({[], [], []}, fn
        {:ok, exchange}, {ok, skip, err} -> {[exchange | ok], skip, err}
        {:skip, file}, {ok, skip, err} -> {ok, [file | skip], err}
        {:error, file, reason}, {ok, skip, err} -> {ok, skip, [{file, reason} | err]}
      end)

    for {file, reason} <- errors do
      Logger.warning("Failed to parse #{file}: #{inspect(reason)}")
    end

    sorted = Enum.sort_by(exchanges, & &1["id"])

    {:ok, sorted, %{skipped: Enum.reverse(skipped), errors: Enum.reverse(errors)}}
  end

  @doc """
  Write extracted interface signatures to `priv/discoveries/interface_signatures.json`.
  """
  @spec write!([map()], String.t()) :: :ok
  def write!(exchanges, output_path \\ CcxtExtract.Paths.priv(Path.join("discoveries", @output_file))) do
    File.mkdir_p!(Path.dirname(output_path))

    with_sigs = Enum.count(exchanges, fn e -> e["interface_signature_count"] > 0 end)
    total_sigs = Enum.sum(Enum.map(exchanges, & &1["interface_signature_count"]))

    output = %{
      "extracted_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "count" => length(exchanges),
      "with_signatures" => with_sigs,
      "total_signatures" => total_sigs,
      "exchanges" => exchanges
    }

    json = Jason.encode!(output, pretty: true)
    File.write!(output_path, json)
    :ok
  end

  @doc """
  Parse a single abstract TypeScript file and extract interface signatures.

  Returns `{:ok, exchange_map}`, `{:skip, filename}` if no Exchange interface,
  or `{:error, filename, reason}` on parse failure.
  """
  @spec parse_file(String.t()) :: {:ok, map()} | {:skip, String.t()} | {:error, String.t(), term()}
  def parse_file(path) do
    source = File.read!(path)
    filename = Path.basename(path)

    case OXC.parse(source, filename) do
      {:ok, ast} ->
        case extract_from_ast(ast, filename) do
          nil -> {:skip, filename}
          exchange -> {:ok, exchange}
        end

      {:error, reason} ->
        {:error, filename, reason}
    end
  end

  @doc """
  Extract interface signatures from a parsed AST.

  Finds the `TSInterfaceDeclaration` and extracts all `TSMethodSignature`
  members with their name, params, and return type. Alias exchanges use
  the parent's interface name (e.g., `interface binance` in binanceus.ts).
  """
  @spec extract_from_ast(map(), String.t()) :: map() | nil
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

  # Path to abstract TypeScript source directory
  defp abstract_src, do: Path.join(CcxtExtract.Paths.ts_src(), "abstract")
end

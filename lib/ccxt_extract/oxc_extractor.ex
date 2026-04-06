defmodule CcxtExtract.OXCExtractor do
  @moduledoc """
  Shared behaviour for OXC-based TypeScript extraction modules.

  Provides default implementations of `extract/0`, `parse_file/1`, and `write!/2`
  that scan a directory of `.ts` files, parse each via OXC, and write results
  to a discovery JSON file. Each module implements callbacks to customize the
  source directory, output file, AST extraction logic, and write statistics.

  ## Usage

      defmodule CcxtExtract.ParseMethods do
        use CcxtExtract.OXCExtractor, output_file: "parse_methods.json"

        @impl true
        def source_dir, do: CcxtExtract.Paths.ts_src()

        @impl true
        def extract_from_ast(ast, filename) do
          # module-specific extraction
        end

        @impl true
        def write_stats(exchanges) do
          %{"with_parse_methods" => Enum.count(exchanges, & &1["parse_method_count"] > 0)}
        end
      end
  """

  @doc "Directory to scan for TypeScript files."
  @callback source_dir() :: String.t()

  @doc "Extract data from a parsed AST for a single file. Return nil to skip."
  @callback extract_from_ast(ast :: map(), filename :: String.t()) :: map() | nil

  @doc "Return module-specific stats to merge into the write envelope."
  @callback write_stats(exchanges :: [map()]) :: map()

  @doc """
  Sets up the using module with default `extract/0`, `parse_file/1`, and `write!/2`.

  ## Options

    * `:output_file` (required) — filename for discovery JSON output
    * `:file_glob` — glob pattern within source_dir (default: `"*.ts"`)
  """
  defmacro __using__(opts) do
    output_file = Keyword.fetch!(opts, :output_file)
    file_glob = Keyword.get(opts, :file_glob, "*.ts")

    quote do
      @behaviour CcxtExtract.OXCExtractor

      require Logger

      @oxc_output_file unquote(output_file)
      @oxc_file_glob unquote(file_glob)

      @doc """
      Extract data from all TypeScript files in the source directory.

      Returns `{:ok, exchanges, stats}` where stats has `:skipped` and `:errors` lists.
      """
      @spec extract() :: {:ok, [map()], map()}
      def extract do
        dir = source_dir()

        if !File.dir?(dir) do
          raise "CCXT source not found at #{dir}. Run `mix ccxt_extract.setup` first."
        end

        files = Path.wildcard(Path.join(dir, @oxc_file_glob))

        if files == [] do
          raise "No .ts files found in #{dir}. CCXT source may be incomplete."
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
      Parse a single TypeScript file and extract data via `extract_from_ast/2`.

      Returns `{:ok, exchange_map}`, `{:skip, filename}` if extraction returns nil,
      or `{:error, filename, reason}` on parse failure.
      """
      @spec parse_file(String.t()) ::
              {:ok, map()} | {:skip, String.t()} | {:error, String.t(), term()}
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
      Write extracted data to the discovery JSON file.
      """
      @spec write!([map()], String.t()) :: :ok
      def write!(exchanges, output_path \\ CcxtExtract.Paths.priv(Path.join("discoveries", @oxc_output_file))) do
        File.mkdir_p!(Path.dirname(output_path))

        base = %{
          "extracted_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "count" => length(exchanges),
          "exchanges" => exchanges
        }

        output = Map.merge(base, write_stats(exchanges))

        json = Jason.encode!(output, pretty: true)
        File.write!(output_path, json)
        :ok
      end

      defoverridable extract: 0, parse_file: 1, write!: 2
    end
  end
end

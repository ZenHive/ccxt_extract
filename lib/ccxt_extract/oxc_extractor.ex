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
          |> CcxtExtract.OXCBatch.reduce_results()

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
      def parse_file(path), do: CcxtExtract.OXCBatch.parse_file(path, &extract_from_ast/2)

      @doc """
      Write extracted data to the discovery JSON file.

      The second argument is either an output path (string, legacy positional
      form used by integration tests) or an options keyword list. Supported
      options:

        * `:output_path` — override the default discovery JSON path
        * `:scope` — `:all` or `MapSet.t(String.t())`. When a MapSet, the
          write merges with any existing aggregate: only entries whose
          `"id"` is in scope get replaced; out-of-scope entries are
          preserved. `:all` (default) overwrites the file wholesale.
        * `:tier_scope` — value from `CcxtExtract.Scope.to_manifest_value/1`,
          stamped into the envelope as `"tier_scope"`. Defaults to `"all"`.
        * `:extracted_at` — override the ISO8601 timestamp (useful for
          reproducible tests).

      Always routes through `CcxtExtract.AggregateWriter.write!/3`, which
      recomputes envelope totals via `write_stats/1` on the final merged
      entries list — closes envelope-vs-entries drift by construction.
      """
      @spec write!([map()], String.t() | keyword()) :: :ok
      def write!(exchanges, output_path_or_opts \\ []) do
        opts =
          case output_path_or_opts do
            path when is_binary(path) -> [output_path: path]
            opts when is_list(opts) -> opts
          end

        output_path =
          Keyword.get(
            opts,
            :output_path,
            CcxtExtract.Paths.priv(Path.join("discoveries", @oxc_output_file))
          )

        writer_opts = [
          entry_key: "exchanges",
          id_key: "id",
          scope: Keyword.get(opts, :scope, :all),
          stats_fn: &write_stats/1,
          tier_scope: Keyword.get(opts, :tier_scope, "all")
        ]

        writer_opts =
          case Keyword.fetch(opts, :extracted_at) do
            {:ok, ts} -> Keyword.put(writer_opts, :extracted_at, ts)
            :error -> writer_opts
          end

        CcxtExtract.AggregateWriter.write!(output_path, exchanges, writer_opts)
      end

      defoverridable extract: 0, parse_file: 1, write!: 2
    end
  end
end

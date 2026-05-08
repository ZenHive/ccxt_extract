defmodule Mix.Tasks.CcxtExtract.ErrorClassHierarchy do
  @shortdoc "Extract CCXT exception class inheritance tree"

  @moduledoc """
  Parses `priv/ccxt/ts/src/base/errorHierarchy.ts` via OXC and writes the
  CCXT exception class inheritance tree (literal nested-object source +
  flat parent map + pre-computed ancestor chains) to
  `priv/discoveries/error_class_hierarchy.json`.

      mix ccxt_extract.error_class_hierarchy

  ## Design note

  Unscoped — the source file is a single global resource (one tree for
  all of CCXT, identical for every exchange). The `:unscoped` mode in
  `ccxt_extract.update`'s OXC-extractor pipeline forwards no scope flags,
  matching `ccxt_extract.base_methods` which is the canonical
  single-file extractor.

  Raises if the source file is missing (run `mix ccxt_extract.setup`
  first) or if the AST does not match the expected literal-object
  shape.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {_opts, leftover, invalid} = OptionParser.parse(args, strict: [])

    if invalid != [] do
      switches = Enum.map_join(invalid, ", ", fn {k, _} -> k end)
      Mix.raise("Unknown option(s): #{switches}")
    end

    if leftover != [] do
      Mix.raise("Unexpected argument(s): #{Enum.join(leftover, ", ")}")
    end

    Mix.shell().info("Extracting CCXT exception class hierarchy from errorHierarchy.ts...")

    case CcxtExtract.ErrorClassHierarchy.extract() do
      {:ok, record} ->
        CcxtExtract.ErrorClassHierarchy.write!(record)

        roots =
          record["flat_parents"]
          |> Enum.filter(fn {_class, parent} -> is_nil(parent) end)
          |> Enum.map_join(", ", fn {class, _} -> class end)

        max_depth =
          record["ancestors"]
          |> Map.values()
          |> Enum.map(&length/1)
          |> Enum.max(fn -> 0 end)

        Mix.shell().info("""
        Done. #{map_size(record["flat_parents"])} exception classes extracted.
          Roots: #{roots}
          Max depth: #{max_depth}
        Output: priv/discoveries/error_class_hierarchy.json
        """)

      {:error, reason} ->
        Mix.raise("Failed to extract error class hierarchy: #{inspect(reason)}")
    end
  end
end

defmodule CcxtExtract.OXCBatch do
  @moduledoc """
  Shared primitives for batch OXC-based TypeScript parsing.

  Factors out the two pieces that `OXCExtractor`, `Methods`, and `Classes`
  all need: parsing a single file and folding a list of per-file results
  into `{entries, skipped, errors}`. Used both by the `OXCExtractor`
  behaviour default implementations and directly by modules whose call
  surface doesn't fit the behaviour (multi-arity `extract/1`, dual-dir
  scans, etc.).

  Callers must pass absolute paths from `CcxtExtract.Paths` read helpers
  (e.g. `Paths.ts_src/0`, `Paths.priv/1`) so `:priv_dir_override` applies.
  """

  @type result :: {:ok, map()} | {:skip, String.t()} | {:error, String.t(), term()}

  @doc """
  Fold a list of per-file parse results into three reversed lists.

  Returns `{entries, skipped, errors}` with entries accumulated in
  reverse order. Callers typically `Enum.sort_by(entries, & &1["id"])`
  afterward, which also normalises order.
  """
  @spec reduce_results([result()]) ::
          {[map()], [String.t()], [{String.t(), term()}]}
  def reduce_results(results) do
    Enum.reduce(results, {[], [], []}, fn
      {:ok, entry}, {ok, skip, err} -> {[entry | ok], skip, err}
      {:skip, file}, {ok, skip, err} -> {ok, [file | skip], err}
      {:error, file, reason}, {ok, skip, err} -> {ok, skip, [{file, reason} | err]}
    end)
  end

  @doc """
  Read and OXC-parse a single TypeScript file, dispatching to `extract_fn`.

  `extract_fn` receives the parsed AST and filename. If it returns `nil`
  the file is reported as `{:skip, filename}`; otherwise the result is
  wrapped as `{:ok, entry}`. Parse failures propagate as
  `{:error, filename, reason}`.
  """
  @spec parse_file(String.t(), (map(), String.t() -> map() | nil)) :: result()
  def parse_file(path, extract_fn) do
    source = File.read!(path)
    filename = Path.basename(path)

    case OXC.parse(source, filename) do
      {:ok, ast} ->
        case extract_fn.(ast, filename) do
          nil -> {:skip, filename}
          entry -> {:ok, entry}
        end

      {:error, reason} ->
        {:error, filename, reason}
    end
  end
end

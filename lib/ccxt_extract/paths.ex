defmodule CcxtExtract.Paths do
  @moduledoc """
  Resolve file paths for CCXT extraction artifacts.

  All paths are anchored to `:code.priv_dir(:ccxt_extract)` so they work
  both in Mix development and in compiled releases.

  ## Read vs write

  Read paths (`priv/1`, `priv_dir/0`, `discoveries/0`, `bundle/0`,
  `version_file/0`, `ts_src/0`) resolve relative to `priv_dir/0`, which
  honors `:priv_dir_override`. Write paths (`out/1`, `out_priv_dir/0`,
  `out_bundle/0`, `out_version_file/0`) resolve relative to
  `out_priv_dir/0`, which honors the narrower `:priv_write_override` first,
  then falls through to `priv_dir/0`.

  This split lets integration tests read from the committed corpus while
  redirecting writes to a per-test tmp dir. A full `:priv_dir_override`
  (with no `:priv_write_override`) redirects both — used by external
  `mix ccxt_extract.update --output /path` runs so every artifact lands
  under the client's directory.

  ## Layout

      priv/
      ├── ccxt/                    # CCXT source (git clone or symlink)
      │   ├── ts/src/              # TypeScript exchange files (for OXC)
      │   └── package.json         # Source version info
      ├── ccxt_bundle.js           # Browser bundle (copied from node_modules during setup)
      ├── ccxt_version.json        # Version tracking
      └── discoveries/             # Extraction output
          ├── exchanges.json
          ├── describe/              # Per-exchange describe() files
          │   ├── _manifest.json
          │   ├── binance.json
          │   └── ...
          └── ...
  """

  @doc """
  Absolute path to the `priv/` directory for READS.

  Honors `Application.get_env(:ccxt_extract, :priv_dir_override)` when set.
  Falls back to `:code.priv_dir(:ccxt_extract)`.
  """
  @spec priv_dir() :: String.t()
  def priv_dir do
    case Application.get_env(:ccxt_extract, :priv_dir_override) do
      nil -> :ccxt_extract |> :code.priv_dir() |> to_string()
      override when is_binary(override) -> override
    end
  end

  @doc """
  Absolute path to the `priv/` directory for WRITES.

  Honors `Application.get_env(:ccxt_extract, :priv_write_override)` first,
  then falls through to `priv_dir/0`. Set `:priv_write_override` to isolate
  writes (e.g. in tests) while keeping reads pointed at the real corpus.
  """
  @spec out_priv_dir() :: String.t()
  def out_priv_dir do
    case Application.get_env(:ccxt_extract, :priv_write_override) do
      nil -> priv_dir()
      override when is_binary(override) -> override
    end
  end

  @doc """
  Absolute path to a file within `priv/` for READS.

      CcxtExtract.Paths.priv("discoveries/exchanges.json")
      #=> "/absolute/path/to/priv/discoveries/exchanges.json"
  """
  @spec priv(String.t()) :: String.t()
  def priv(relative_path) do
    Path.join(priv_dir(), relative_path)
  end

  @doc """
  Absolute path to a file within `priv/` for WRITES.

  Mirrors `priv/1` but resolves via `out_priv_dir/0`. Use for every path
  handed to a writer (`DiscoveryWriter.write!/3`, `AggregateWriter.write!/3`,
  `Pipeline.write!/3`, `File.write!/2`, etc.).
  """
  @spec out(String.t()) :: String.t()
  def out(relative_path) do
    Path.join(out_priv_dir(), relative_path)
  end

  @doc "Path to the CCXT browser bundle for READS (resolved via `priv_dir/0`)."
  @spec bundle() :: String.t()
  def bundle, do: priv("ccxt_bundle.js")

  @doc "Path to the CCXT browser bundle for WRITES (setup copies to this target)."
  @spec out_bundle() :: String.t()
  def out_bundle, do: out("ccxt_bundle.js")

  @doc "Path to the CCXT TypeScript source directory."
  @spec ts_src() :: String.t()
  def ts_src, do: priv("ccxt/ts/src")

  @doc "Path to the version tracking file for READS (resolved via `priv_dir/0`)."
  @spec version_file() :: String.t()
  def version_file, do: priv("ccxt_version.json")

  @doc "Path to the version tracking file for WRITES (setup stamps this target)."
  @spec out_version_file() :: String.t()
  def out_version_file, do: out("ccxt_version.json")

  @doc "Path to the discoveries output directory (READ)."
  @spec discoveries() :: String.t()
  def discoveries, do: priv("discoveries")
end

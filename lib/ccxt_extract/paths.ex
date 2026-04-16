defmodule CcxtExtract.Paths do
  @moduledoc """
  Resolve file paths for CCXT extraction artifacts.

  All paths are anchored to `:code.priv_dir(:ccxt_extract)` so they work
  both in Mix development and in compiled releases.

  Tests can redirect the whole `priv/` tree to a temporary directory by
  setting the `:priv_dir_override` application env; see `priv_dir/0`.

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
  Absolute path to the `priv/` directory.

  Honors `Application.get_env(:ccxt_extract, :priv_dir_override)` when set,
  which lets integration tests redirect the whole `priv/` tree to a
  temporary directory. Falls back to `:code.priv_dir(:ccxt_extract)`.
  """
  @spec priv_dir() :: String.t()
  def priv_dir do
    case Application.get_env(:ccxt_extract, :priv_dir_override) do
      nil -> :ccxt_extract |> :code.priv_dir() |> to_string()
      override when is_binary(override) -> override
    end
  end

  @doc """
  Absolute path to a file within `priv/`.

      CcxtExtract.Paths.priv("discoveries/exchanges.json")
      #=> "/absolute/path/to/priv/discoveries/exchanges.json"
  """
  @spec priv(String.t()) :: String.t()
  def priv(relative_path) do
    Path.join(priv_dir(), relative_path)
  end

  @doc "Path to the CCXT browser bundle (copied to priv during setup)."
  @spec bundle() :: String.t()
  def bundle, do: priv("ccxt_bundle.js")

  @doc "Path to the CCXT TypeScript source directory."
  @spec ts_src() :: String.t()
  def ts_src, do: priv("ccxt/ts/src")

  @doc "Path to the version tracking file."
  @spec version_file() :: String.t()
  def version_file, do: priv("ccxt_version.json")

  @doc "Path to the discoveries output directory."
  @spec discoveries() :: String.t()
  def discoveries, do: priv("discoveries")
end

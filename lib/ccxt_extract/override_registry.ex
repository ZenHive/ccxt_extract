defmodule CcxtExtract.OverrideRegistry do
  @moduledoc """
  Load and validate per-exchange curated override files from `priv/overrides/<id>.json`.

  These are the hand-curated gap-fill entries described in the three-tier
  extraction model (raw / derived / override). They carry knowledge the AST
  walker and runtime probes cannot reach — imperative signing quirks,
  exchange-specific inversions, CCXT bugs — each with a required `reason`
  and an optional `verified_against` citation or `unverified: true` flag.

  Distinct from `CcxtExtract.Overrides`, which extracts class-level method
  override structure (parent vs child method inventory) from TS source.

  ## File format (v1)

      {
        "schema_version": "1",
        "overrides": [
          {
            "path": "/structure/authenticated_sections",
            "value": ["private"],
            "reason": "sign() has no checkRequiredCredentials() gate",
            "verified_against": "priv/ccxt/ts/src/hyperliquid.ts:4877"
          }
        ]
      }

  Rules enforced at load time (failures raise — invalid override files are
  build-time bugs, not runtime conditions). Validation failures raise
  `RuntimeError`; malformed JSON propagates as `Jason.DecodeError` and
  unreadable files as `File.Error`:

    * `schema_version` must be `"1"`.
    * `overrides` must be a non-empty list.
    * Each entry requires `path`, `value`, `reason`; optional
      `verified_against`, `unverified`. Unknown keys are rejected.
    * `path` must be an RFC 6901 JSON Pointer starting with `/`.
    * `reason` must be a non-empty string.
    * `verified_against` and `unverified: true` are mutually exclusive.
    * Paths within a file must be unique.

  ## Task 60 scope

  Task 60 ships the contract (format + loader + SCHEMA.md + JSON Schema).
  The generic merge stage that applies every entry to the emitted exchange
  map lands with Task 61b. Today only `find/2` against
  `/structure/authenticated_sections` is consumed (by the pipeline's
  private `resolve_auth_override/3`).
  """

  alias CcxtExtract.Paths

  @override_schema_version "1"
  @required_entry_keys ~w(path value reason)
  @allowed_entry_keys ~w(path value reason verified_against unverified)

  @doc """
  Read `priv/overrides/<id>.json` and validate its shape.

  Returns the parsed `overrides` list on success, `:none` when no override
  file exists for this exchange. Raises on invalid files (unknown keys,
  missing required keys, duplicate paths, mutually-exclusive flags both set).
  """
  @spec load(String.t()) :: [map()] | :none
  def load(exchange_id) when is_binary(exchange_id) do
    load_path(Paths.priv("overrides/#{exchange_id}.json"))
  end

  @doc """
  Read and validate an override file at an explicit path. Same return
  contract as `load/1`. Exists to let tests (or future tooling) validate
  override fixtures that don't live under `priv/overrides/`.
  """
  @spec load_path(Path.t()) :: [map()] | :none
  def load_path(path) when is_binary(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> Jason.decode!()
      |> validate!(path)
    else
      :none
    end
  end

  @doc """
  Find an override entry by its JSON Pointer path.

  Returns `{:ok, entry}` when present, `:none` otherwise. Exact string
  match — path resolution (e.g. normalizing `//foo` to `/foo`) is a
  Task 61b concern.
  """
  @spec find([map()], String.t()) :: {:ok, map()} | :none
  def find(overrides, json_pointer) when is_list(overrides) and is_binary(json_pointer) do
    case Enum.find(overrides, &(&1["path"] == json_pointer)) do
      nil -> :none
      entry -> {:ok, entry}
    end
  end

  @doc """
  List every exchange ID with a curated override file in `priv/overrides/`.

  Used by the contract-test invariant and the integration test registry.
  """
  @spec list_exchanges() :: [String.t()]
  def list_exchanges do
    dir = Paths.priv("overrides")

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&String.trim_trailing(&1, ".json"))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @doc """
  Apply every override entry in `overrides` to `exchange_map`, returning
  the transformed map. Each entry's `value` is placed at the RFC 6901
  `path`, using `put_in/3` over a string-key list resolved from the
  JSON Pointer.

  Entry order is preserved; since the loader rejects duplicate paths
  within a single file, no in-file conflicts are possible.

  Values are applied verbatim — no sorting, dedup, or other normalization.
  Authors are responsible for canonical form. The prior narrow consumer
  (`Pipeline.resolve_auth_override/3`) did `Enum.sort(Enum.uniq/1)` on
  `authenticated_sections`; `apply_all/2` does not.

  ## Depth limitation

  Only string-key segments are supported today. Segments that look like
  array indices (non-negative integers) raise — array handling with
  `Access.at/1` lands when a real override file needs a deep pointer.
  All current (Task 60) override files use shallow paths like
  `/structure/authenticated_sections`.
  """
  @spec apply_all(map(), [map()]) :: map()
  def apply_all(exchange_map, overrides) when is_map(exchange_map) and is_list(overrides) do
    Enum.reduce(overrides, exchange_map, fn entry, acc ->
      keys = pointer_to_keys(entry["path"])
      put_in(acc, keys, entry["value"])
    end)
  end

  @doc """
  Parse an RFC 6901 JSON Pointer into a list of string keys usable with
  `Kernel.get_in/2` and `Kernel.put_in/3`.

  Raises on pointers that don't start with `/` or that contain a
  numeric segment (array indices are pending — see `apply_all/2`).

  Handles the two RFC 6901 escape sequences in the mandated order:
  `~1` → `/` first, then `~0` → `~`. This ensures `~01` correctly
  round-trips to the literal string `~1`.

  Edge case: `"/"` resolves to the empty-string key `[""]` per RFC 6901
  (it points at the `""` member of the root object). No shipped override
  file uses this form, but it parses without error.
  """
  @spec pointer_to_keys(String.t()) :: [String.t()]
  def pointer_to_keys("/" <> rest) do
    rest
    |> String.split("/")
    |> Enum.map(&unescape_segment/1)
  end

  def pointer_to_keys(other) do
    raise "Invalid JSON Pointer #{inspect(other)}: must start with '/'"
  end

  defp unescape_segment(segment) do
    if numeric_segment?(segment) do
      # TODO(Task 104): extend to Access.at/1 when a real override file
      # needs deep-pointer array indexing. Shallow string-key pointers
      # cover every shipped override as of 2026-04-16.
      raise """
      Invalid JSON Pointer segment #{inspect(segment)}: array index segment \
      is not yet supported. See ROADMAP.md Task 104.
      """
    end

    segment
    |> String.replace("~1", "/")
    |> String.replace("~0", "~")
  end

  defp numeric_segment?(segment) do
    segment != "" and String.match?(segment, ~r/^\d+$/)
  end

  # --- Validation ---

  defp validate!(%{"schema_version" => @override_schema_version, "overrides" => overrides} = data, path)
       when is_list(overrides) do
    if overrides == [] do
      raise "Invalid override file #{path}: \"overrides\" list must be non-empty"
    end

    unknown_top = Map.keys(data) -- ["schema_version", "overrides"]

    if unknown_top != [] do
      raise "Invalid override file #{path}: unknown top-level keys #{inspect(unknown_top)}"
    end

    overrides
    |> Enum.with_index()
    |> Enum.each(&validate_entry!(&1, path))

    validate_unique_paths!(overrides, path)
    overrides
  end

  defp validate!(%{"schema_version" => v}, path) do
    raise "Invalid override file #{path}: expected schema_version \"1\", got #{inspect(v)}"
  end

  defp validate!(_data, path) do
    raise ~s(Invalid override file #{path}: missing required top-level keys "schema_version" and "overrides")
  end

  defp validate_entry!({entry, index}, path) when is_map(entry) do
    ctx = {path, index}
    check_entry_keys!(entry, ctx)
    check_entry_path!(entry, ctx)
    check_entry_reason!(entry, ctx)
    check_entry_optional_fields!(entry, ctx)
  end

  defp validate_entry!({entry, index}, path) do
    raise "Invalid override file #{path}: entry[#{index}] must be a map, got #{inspect(entry)}"
  end

  defp check_entry_keys!(entry, {path, index}) do
    missing = Enum.reject(@required_entry_keys, &Map.has_key?(entry, &1))
    unknown = Map.keys(entry) -- @allowed_entry_keys

    cond do
      missing != [] ->
        raise "Invalid override file #{path}: entry[#{index}] missing required keys #{inspect(missing)}"

      unknown != [] ->
        raise "Invalid override file #{path}: entry[#{index}] has unknown keys #{inspect(unknown)}"

      true ->
        :ok
    end
  end

  defp check_entry_path!(entry, {path, index}) do
    value = entry["path"]

    if !(is_binary(value) and String.starts_with?(value, "/")) do
      raise "Invalid override file #{path}: entry[#{index}] path must be a JSON Pointer string starting with '/', got #{inspect(value)}"
    end
  end

  defp check_entry_reason!(entry, {path, index}) do
    value = entry["reason"]

    if !(is_binary(value) and value != "") do
      raise "Invalid override file #{path}: entry[#{index}] reason must be a non-empty string"
    end
  end

  defp check_entry_optional_fields!(entry, ctx) do
    check_verified_against!(entry, ctx)
    check_unverified!(entry, ctx)
    check_verification_exclusivity!(entry, ctx)
  end

  defp check_verified_against!(entry, {path, index}) do
    if Map.has_key?(entry, "verified_against") and not is_binary(entry["verified_against"]) do
      raise "Invalid override file #{path}: entry[#{index}] verified_against must be a string"
    end
  end

  defp check_unverified!(entry, {path, index}) do
    if Map.has_key?(entry, "unverified") and not is_boolean(entry["unverified"]) do
      raise "Invalid override file #{path}: entry[#{index}] unverified must be a boolean"
    end
  end

  defp check_verification_exclusivity!(entry, {path, index}) do
    if Map.has_key?(entry, "verified_against") and Map.get(entry, "unverified") == true do
      raise ~s(Invalid override file #{path}: entry[#{index}] cannot set both "verified_against" and "unverified": true)
    end
  end

  defp validate_unique_paths!(overrides, path) do
    paths = Enum.map(overrides, & &1["path"])
    duplicates = paths -- Enum.uniq(paths)

    if duplicates != [] do
      raise "Invalid override file #{path}: duplicate paths #{inspect(Enum.uniq(duplicates))}"
    end
  end
end

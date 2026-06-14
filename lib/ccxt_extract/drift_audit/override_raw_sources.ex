defmodule CcxtExtract.DriftAudit.OverrideRawSources do
  @moduledoc """
  Maps curated override JSON Pointer paths to the raw emission pointers whose
  drift should trigger a stale-override finding in `CcxtExtract.DriftAudit`.

  Overrides mask derived output — comparing only the override-applied final
  value misses upstream raw changes that may invalidate the curation. This
  module names the precise raw subtree(s) to diff so unrelated `raw` drift does
  not mark every override stale.
  """

  @typedoc "RFC 6901 pointer into a v4-shaped exchange map."
  @type pointer :: String.t()

  # v4 override pointer → raw source pointer(s) that feed derivation at that
  # path. Mirrors validate_overrides probes and pipeline derive inputs.
  @sources %{
    "/auth/authenticated_sections" => ["/auth/sign_method", "/raw/describe/api"],
    "/raw/url_templates" => ["/raw/url_templates"]
  }

  @doc """
  Return the raw source pointer(s) for an override path (already translated to
  v4). Unknown paths return `[]` — drift_audit falls back to final-value diff
  only for those entries.
  """
  @spec pointers(pointer()) :: [pointer()]
  def pointers(override_ptr) when is_binary(override_ptr) do
    Map.get(@sources, override_ptr, [])
  end
end

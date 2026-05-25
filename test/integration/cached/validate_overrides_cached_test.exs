defmodule CcxtExtract.ValidateOverridesCachedTest do
  @moduledoc """
  Cached integration: validate committed `priv/overrides/` against the
  committed discovery corpus (no QuickBEAM / :extraction).
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.ValidateOverrides

  @discoveries CcxtExtract.Paths.discoveries()
  @overrides CcxtExtract.Paths.priv("overrides")

  test "all committed override files pass validation (0 mismatches, 0 errors)" do
    assert {:ok, report} =
             ValidateOverrides.run(
               discoveries_dir: @discoveries,
               overrides_dir: @overrides
             )

    s = report["summary"]
    assert s["mismatches"] == 0
    assert s["errors"] == 0
    assert s["warnings"] == 0

    # gateio may lack describe discovery under scoped corpus — allow informational unverified
    strict_unverified =
      report["exchanges"]
      |> Enum.flat_map(& &1["entries"])
      |> Enum.filter(fn entry ->
        entry["status"] == "unverified" and entry["explicit_unverified"] == true
      end)

    assert strict_unverified == []
  end
end

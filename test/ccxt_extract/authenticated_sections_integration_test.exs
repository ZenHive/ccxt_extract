defmodule CcxtExtract.AuthenticatedSectionsIntegrationTest do
  @moduledoc """
  End-to-end assertions over the emitted per-exchange JSON in priv/output/.

  Guards two invariants:

  1. Every *priority-tier* exchange (tier1/tier2/tier3/dex) whose `describe.api`
     has a `/private/i` top-level key must have a non-empty
     `authenticated_sections` — either by AST derivation or via an entry in
     `priv/overrides/`. Exchanges that legitimately lack a
     `checkRequiredCredentials()` gate (or use a sign() shape the walker
     cannot reach) appear in the allowlist below with a justification.
     Unclassified exchanges are excluded per CLAUDE.md tier-based scoping:
     they receive raw extraction only and default to null/empty for derived
     recipes until a consumer promotes them.

  2. Every file in `priv/overrides/` must correspond to an exchange where
     pure AST derivation would have returned an empty/nil list. If the
     walker learns a new shape and an override becomes dead code, this test
     catches it so the override can be removed.
  """
  use ExUnit.Case, async: true

  @output_dir Path.join([File.cwd!(), "priv", "output"])
  @overrides_dir Path.join([File.cwd!(), "priv", "overrides"])

  # lbank: `api` is passed as a 2-tuple [marketType, access] — describe.api keys
  #   are market types ('contract', 'spot'), not auth classes. No top-level
  #   section maps to auth, so empty is semantically correct.
  @empty_allowlist ["lbank"]

  describe "authenticated_sections population" do
    test "every exchange with /private/i section has non-empty authenticated_sections" do
      failures =
        @output_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.reject(&String.starts_with?(&1, "_"))
        |> Enum.map(&Path.join(@output_dir, &1))
        |> Enum.flat_map(&check_exchange/1)

      assert failures == [],
             "Exchanges with /private/i api keys but empty authenticated_sections:\n  " <>
               Enum.join(failures, "\n  ")
    end
  end

  describe "override registry" do
    test "every override file corresponds to an exchange where AST derivation yields empty" do
      dead_overrides =
        @overrides_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.flat_map(&check_override_alive/1)

      assert dead_overrides == [],
             "Overrides that appear to be dead code (AST now extracts non-empty):\n  " <>
               Enum.join(dead_overrides, "\n  ")
    end

    test "every override file has the required schema fields" do
      missing_fields =
        @overrides_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.flat_map(fn file ->
          path = Path.join(@overrides_dir, file)
          data = path |> File.read!() |> Jason.decode!()
          id = Path.basename(file, ".json")

          cond do
            not is_list(data["authenticated_sections"]) -> ["#{id}: missing/invalid authenticated_sections"]
            not is_binary(data["reason"]) -> ["#{id}: missing reason"]
            not is_binary(data["verified_against"]) -> ["#{id}: missing verified_against"]
            true -> []
          end
        end)

      assert missing_fields == [],
             "Override files missing required fields:\n  " <> Enum.join(missing_fields, "\n  ")
    end
  end

  # --- helpers ---

  defp check_exchange(path) do
    id = Path.basename(path, ".json")
    data = path |> File.read!() |> Jason.decode!()
    tier = get_in(data, ["exchange", "tier"])
    api = get_in(data, ["runtime", "describe", "api"]) || %{}
    auth = get_in(data, ["structure", "authenticated_sections"]) || []

    has_private_key? =
      api
      |> Map.keys()
      |> Enum.any?(fn k -> k =~ ~r/private/i end)

    cond do
      # Per CLAUDE.md tier-based scoping: derived recipes are scoped to priority
      # tiers. Unclassified exchanges receive raw extraction only; empty
      # authenticated_sections is the documented "null + reason" default.
      tier == "unclassified" -> []
      not has_private_key? -> []
      auth != [] -> []
      id in @empty_allowlist -> []
      true -> ["#{id} (api keys: #{inspect(Map.keys(api))})"]
    end
  end

  defp check_override_alive(file) do
    id = Path.basename(file, ".json")
    output_path = Path.join(@output_dir, "#{id}.json")

    if File.exists?(output_path) do
      override = @overrides_dir |> Path.join(file) |> File.read!() |> Jason.decode!()
      override_sections = override["authenticated_sections"] || []

      data = output_path |> File.read!() |> Jason.decode!()
      sign_method = get_in(data, ["structure", "sign_method"])
      api_keys = Map.keys(get_in(data, ["runtime", "describe", "api"]) || %{})

      derived = CcxtExtract.AuthenticatedSections.derive(sign_method, api_keys) || []

      if derived != [] and Enum.sort(Enum.uniq(derived)) == Enum.sort(override_sections) do
        ["#{id}: AST derivation now matches override — override is redundant"]
      else
        []
      end
    else
      ["#{id}: override has no corresponding exchange output"]
    end
  end
end

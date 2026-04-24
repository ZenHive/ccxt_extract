defmodule CcxtExtract.SignRecipe do
  @moduledoc """
  Per-section declarative signing recipe.

  Shape scaffold for Phase 10 of the consumer contract. Every authenticated
  API section gets one recipe record keyed in `structure.sign_recipe` by
  section name (e.g. `"private"`, `"sapi"`, `"fapiPrivate"`). A consumer
  that reads the record can construct an authenticated HTTP request without
  walking the raw `sign()` AST.

  ## Three-tier contract

  Each record has six derivation fields plus two metadata fields:

    * `crypto_op`          — populated by Task 65
    * `signature_placement` — populated by Task 65
    * `canonical_string`   — populated by Tasks 66a / 66b (HMAC families)
    * `auth_headers`       — populated by Task 67
    * `nonce`              — populated by Task 67
    * `pre_sign_transforms` — populated by Task 68
    * `unresolved_reason`  — closed-vocabulary tag; `"not_yet_derived"` in the scaffold
    * `patch_count`        — Three-Strikes Rule counter (see CLAUDE.md)

  Task 64 ships the scaffold: `build_default/1` returns a map of section-keyed
  all-null recipes with `unresolved_reason: "not_yet_derived"` and
  `patch_count: 0`. Tasks 65\u201369 flip individual fields from `null` to
  derived values; when every derivation field is non-null, Task 69 flips
  `unresolved_reason` to `null`.

  ## Authoritative schema

  The record shape is enforced by `priv/schema/sign_recipe_v1.json`. An
  equivalent copy lives under `priv/schema/exchange_v3.json#/$defs/SignRecipeRecord`
  and the pipeline validator uses that copy during `mix ccxt_extract.validate`.
  Two contract-test invariants (`sign_recipe_keys_match_auth_sections` and
  `sign_recipe_shape_valid`) re-assert the shape from a different angle.

  ## Honesty Rule

  An exchange that has no authenticated sections gets `sign_recipe => %{}`.
  Every authenticated section present in `structure.authenticated_sections`
  MUST have a matching key here; the contract-test invariant
  `sign_recipe_keys_match_auth_sections` fails loudly on drift.
  """

  @typedoc "Closed-vocabulary tag describing why derivation fields are null."
  @type unresolved_reason :: nil | String.t()

  @typedoc "A single per-section signing recipe record. See moduledoc."
  @type recipe :: %{
          required(String.t()) => term()
        }

  @typedoc "`section_name => recipe` map, shape of `structure.sign_recipe`."
  @type recipe_map :: %{optional(String.t()) => recipe()}

  @initial_unresolved_reason "not_yet_derived"

  @required_keys ~w(crypto_op canonical_string signature_placement auth_headers nonce pre_sign_transforms unresolved_reason patch_count)
  @unresolved_reasons ~w(not_yet_derived custom_signing_family ambiguous_ast no_sign_method)

  # Subset of `@unresolved_reasons` that short-circuits every derivation
  # module (CanonicalString, AuthHeaders, Nonce) to `nil`. `"not_yet_derived"`
  # is intentionally NOT terminal — it's the scaffold default, meaning
  # later derivation tasks will flip individual fields.
  @terminal_reasons ~w(ambiguous_ast custom_signing_family no_sign_method)

  @doc """
  The eight required keys on every `structure.sign_recipe` record.
  Authoritative for contract-test shape validation — keep in sync with
  `priv/schema/sign_recipe_v1.json#/required` and
  `priv/schema/exchange_v3.json#/$defs/SignRecipeRecord/required`.
  """
  @spec required_keys() :: [String.t()]
  def required_keys, do: @required_keys

  @doc """
  Closed vocabulary for `unresolved_reason`. Must stay in sync with the
  enum in `priv/schema/sign_recipe_v1.json` and the `SignRecipeRecord`
  copy in `priv/schema/exchange_v3.json`.
  """
  @spec unresolved_reasons() :: [String.t()]
  def unresolved_reasons, do: @unresolved_reasons

  @doc """
  Subset of `unresolved_reasons/0` that short-circuits every derivation
  module (CanonicalString, AuthHeaders, Nonce) to `nil`. `"not_yet_derived"`
  is NOT terminal — it's the scaffold default that later tasks flip.

  Callers typically use this as a compile-time module-attribute source:

      @terminal_reasons CcxtExtract.SignRecipe.terminal_reasons()
      def derive(..., reason) when reason in @terminal_reasons, do: nil
  """
  @spec terminal_reasons() :: [String.t()]
  def terminal_reasons, do: @terminal_reasons

  @doc """
  Return `true` if `reason` is a terminal short-circuit for derivation
  modules. Non-guard variant for `cond`/`case` sites; guard sites should
  use the module-attribute idiom documented on `terminal_reasons/0`.
  """
  @spec terminal_reason?(term()) :: boolean()
  def terminal_reason?(reason) when is_binary(reason), do: reason in @terminal_reasons
  def terminal_reason?(_), do: false

  @doc """
  Return the all-null scaffold for a single recipe record. Used as the
  default value for every authenticated section before Phase 10 derivation
  tasks populate individual fields.
  """
  @spec null_recipe() :: recipe()
  def null_recipe do
    %{
      "crypto_op" => nil,
      "canonical_string" => nil,
      "signature_placement" => nil,
      "auth_headers" => nil,
      "nonce" => nil,
      "pre_sign_transforms" => nil,
      "unresolved_reason" => @initial_unresolved_reason,
      "patch_count" => 0
    }
  end

  @doc """
  Build the default `section_name => recipe` map from a list of authenticated
  section names.

  Accepts `nil` (exchange has no `sign()` AST) or an empty list (sign() exists
  but no `checkRequiredCredentials()` gates) — both return an empty map, which
  is the Honesty-Rule-correct shape: "this exchange authenticates zero
  sections, here are zero recipes." Consumers distinguish the two cases via
  `structure.authenticated_sections` itself (null vs empty list), not via
  `sign_recipe`.

  Duplicate section names collapse; section names are not re-sorted here
  because `build_default/1` trusts its caller's ordering (typically
  `AuthenticatedSections.derive/2`, which already sorts).
  """
  @spec build_default([String.t()] | nil) :: recipe_map()
  def build_default(nil), do: %{}
  def build_default([]), do: %{}

  def build_default(auth_sections) when is_list(auth_sections) do
    Map.new(auth_sections, fn section when is_binary(section) ->
      {section, null_recipe()}
    end)
  end
end

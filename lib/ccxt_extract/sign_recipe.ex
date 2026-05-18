defmodule CcxtExtract.SignRecipe do
  @moduledoc """
  Per-section declarative signing recipe.

  Shape scaffold for Phase 10 of the consumer contract. Every authenticated
  API section gets one recipe record keyed in `structure.sign_recipe` by
  section name (e.g. `"private"`, `"sapi"`, `"fapiPrivate"`). A consumer
  that reads the record can construct an authenticated HTTP request without
  walking the raw `sign()` AST.

  ## Three-tier contract

  Each record has seven derivation fields plus two metadata fields:

    * `crypto_op`          — populated by Task 65
    * `signature_placement` — populated by Task 65
    * `canonical_string`   — populated by Tasks 66a / 66b (HMAC families)
    * `auth_headers`       — populated by Task 67
    * `nonce`              — populated by Task 67
    * `timestamp`          — populated by Task 72 (timestamp `{source, format}`,
      currently mirrors `nonce` since the same AST classifier produces both;
      surfaced as a distinct field so v4 consumers read the canonical
      `auth.sign_recipe.<section>.timestamp` path. Kept additive to v3 for
      the grace window.)
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
  equivalent copy lives under `priv/schema/exchange_v4.json#/$defs/SignRecipeRecord`
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

  @required_keys ~w(crypto_op canonical_string signature_placement auth_headers nonce timestamp pre_sign_transforms unresolved_reason patch_count)
  @derivation_fields ~w(crypto_op canonical_string signature_placement auth_headers nonce timestamp pre_sign_transforms)
  @unresolved_reasons ~w(not_yet_derived custom_signing_family ambiguous_ast no_sign_method)

  # Subset of `@unresolved_reasons` that short-circuits every derivation
  # module (CanonicalString, AuthHeaders, Nonce) to `nil`. `"not_yet_derived"`
  # is intentionally NOT terminal — it's the scaffold default, meaning
  # later derivation tasks will flip individual fields.
  @terminal_reasons ~w(ambiguous_ast custom_signing_family no_sign_method)

  @doc """
  The nine required keys on every `structure.sign_recipe` record.
  Authoritative for contract-test shape validation — keep in sync with
  `priv/schema/sign_recipe_v1.json#/required` and
  `priv/schema/exchange_v4.json#/$defs/SignRecipeRecord/required`.
  """
  @spec required_keys() :: [String.t()]
  def required_keys, do: @required_keys

  @doc """
  The seven derivation fields on every `structure.sign_recipe` record —
  the strict subset of `required_keys/0` that Phase 10 tasks populate
  field-by-field (Tasks 65–68). The biconditional enforced by Task 69
  says `unresolved_reason` is `nil` iff every field in this list is
  non-nil on the record. `required_keys/0 -- derivation_fields/0`
  yields the two metadata keys (`unresolved_reason`, `patch_count`)
  that are NOT subject to the biconditional.
  """
  @spec derivation_fields() :: [String.t()]
  def derivation_fields, do: @derivation_fields

  @doc """
  Return `true` if every key in `derivation_fields/0` is present on the
  recipe record AND non-nil. Returns `false` on malformed input (non-map
  or missing keys) — the safe default is "do not flip unresolved_reason"
  when we can't prove the record is fully populated.

  Used by `CcxtExtract.SignRecipe.Derive` (write-side flip) and
  `CcxtExtract.ContractTest` (read-side invariant) — shared predicate
  so both sites agree on "populated" semantics. Empty list / map /
  string count as populated (non-nil) — the honest-empty cases
  (`auth_headers: []`) must pass through without forcing a tag.
  """
  @spec all_derivation_fields_populated?(term()) :: boolean()
  def all_derivation_fields_populated?(record) when is_map(record) do
    Enum.all?(@derivation_fields, fn key ->
      case Map.fetch(record, key) do
        {:ok, nil} -> false
        {:ok, _value} -> true
        :error -> false
      end
    end)
  end

  def all_derivation_fields_populated?(_), do: false

  @doc """
  Closed vocabulary for `unresolved_reason`. Must stay in sync with the
  enum in `priv/schema/sign_recipe_v1.json` and the `SignRecipeRecord`
  copy in `priv/schema/exchange_v4.json`.
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
      "timestamp" => nil,
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

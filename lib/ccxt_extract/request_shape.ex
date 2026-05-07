defmodule CcxtExtract.RequestShape do
  @moduledoc """
  Per-section declarative HTTP request envelope (verb + path + body encoding).

  Phase 11 / Tasks 70 + 71. Companion to `CcxtExtract.SignRecipe` —
  where SignRecipe pins HOW a request is signed, RequestShape pins WHAT
  the request envelope looks like before signing: the HTTP verb(s), the
  path template(s), and the body wire encoding. Together the two
  complete the consumer-facing contract for `(section, path)` →
  outbound HTTP request, minus the signature bytes.

  ## Three-tier contract

  Each authenticated section gets one record keyed in
  `structure.request_shape` by section name. The record has three
  derivation fields plus two metadata fields:

    * `endpoints`         — Axis A, Task 70: ordered list of
      `%{http_verb, path_template, path_params}` records collected by
      walking `runtime.describe.api[<section>]`. Honest empty `[]`
      when the section is in `describe.api` but has no leaf method
      entries (rare); `nil` when the section subtree is missing or
      malformed.

    * `body_encoding`     — Axis B, Task 71: one of
      `"json"` / `"form_urlencoded"` / `"query_string"` / `"none"`,
      derived from the `body = this.X(...)` branches of `sign()`.
      `nil` when sign() is missing or the body assignment is
      ambiguous.

    * `content_type`      — Axis B, Task 71: HTTP `Content-Type`
      header value derived from sign() AST literals (e.g.
      `"application/json"`). `nil` when the section never assigns
      `Content-Type` in sign() AND `body_encoding == "none"`. When
      `body_encoding != "none"` and we couldn't pin a literal,
      `content_type` falls back to the canonical mapping for the
      derived encoding (`"application/json"` for `"json"`,
      `"application/x-www-form-urlencoded"` for `"form_urlencoded"`).

    * `unresolved_reason` — closed-vocabulary tag explaining why
      derivation fields are null. `"not_yet_derived"` is the scaffold
      default. Tasks 70 + 71 flip individual fields; the biconditional
      below flips the tag itself.

    * `patch_count`       — Three-Strikes Rule counter. At 3, migrate
      the section's request_shape to `priv/overrides/<id>.json`
      rather than continuing to stretch derivation.

  ## Honesty Rule biconditional

  Mirrors Task 69's sign_recipe biconditional:

      unresolved_reason == nil  ⇔  every derivation field is "populated"

  where "populated" is defined by `all_derivation_fields_populated?/1`.
  The predicate accepts honest-empty values (e.g. `endpoints: []`) but
  rejects `nil`. The one nuance: when `body_encoding == "none"`,
  `content_type: nil` is treated as honest-empty (no body → no
  Content-Type). The predicate encodes this exception inline so write-
  side (`Derive.derive/3`) and read-side (`ContractTest.check_request_shape_honesty_valid/2`)
  agree on "populated".

  ## Closed vocabulary for unresolved_reason

    * `"not_yet_derived"`        — scaffold default; flipped by the
      biconditional once all three derivation fields populate.

    * `"no_sign_method"`         — sign() AST is absent (alias
      exchanges that resolve via parent). Mirrors SignRecipe's tag
      with the same name.

    * `"no_describe_api"`        — `runtime.describe.api` is missing
      or non-map; cannot enumerate endpoints.

    * `"section_not_in_api"`     — the authenticated section name
      doesn't resolve to a subtree in `describe.api`.

    * `"ambiguous_body"`         — sign() assigns `body` from
      multiple distinct encoders without verb-conditional branching
      that we can disambiguate (binance's RSA/HMAC fork-class).

  ## Authoritative schema

  The record shape is enforced by
  `priv/schema/exchange_v3.json#/$defs/RequestShapeRecord`. Two
  contract-test invariants (`request_shape_keys_match_auth_sections`
  and `request_shape_shape_valid`) re-assert the shape from a
  different angle.

  ## Honesty Rule

  An exchange that has no authenticated sections gets
  `request_shape => %{}`. Every authenticated section present in
  `structure.authenticated_sections` MUST have a matching key here.
  The contract-test invariant `request_shape_keys_match_auth_sections`
  fails loudly on drift.
  """

  @typedoc "Closed-vocabulary tag describing why derivation fields are null."
  @type unresolved_reason :: nil | String.t()

  @typedoc "A single per-section request shape record. See moduledoc."
  @type record :: %{required(String.t()) => term()}

  @typedoc "`section_name => record` map, shape of `structure.request_shape`."
  @type record_map :: %{optional(String.t()) => record()}

  @initial_unresolved_reason "not_yet_derived"

  @required_keys ~w(endpoints body_encoding content_type unresolved_reason patch_count)
  @derivation_fields ~w(endpoints body_encoding content_type)

  @unresolved_reasons ~w(not_yet_derived no_sign_method no_describe_api section_not_in_api ambiguous_body)

  # Subset of `@unresolved_reasons` that short-circuits every derivation
  # module to `nil`. `"not_yet_derived"` is intentionally NOT terminal —
  # it's the scaffold default that later derivation passes flip.
  @terminal_reasons ~w(no_sign_method no_describe_api section_not_in_api)

  @body_encodings ~w(json form_urlencoded query_string none)

  @content_type_for_encoding %{
    "json" => "application/json",
    "form_urlencoded" => "application/x-www-form-urlencoded",
    "query_string" => nil,
    "none" => nil
  }

  @doc """
  The five required keys on every `structure.request_shape` record.
  Authoritative for contract-test shape validation — keep in sync
  with `priv/schema/exchange_v3.json#/$defs/RequestShapeRecord/required`.
  """
  @spec required_keys() :: [String.t()]
  def required_keys, do: @required_keys

  @doc """
  The three derivation fields populated by Tasks 70 + 71. The
  biconditional says `unresolved_reason` is `nil` iff every field in
  this list is "populated" per `all_derivation_fields_populated?/1`.
  """
  @spec derivation_fields() :: [String.t()]
  def derivation_fields, do: @derivation_fields

  @doc """
  Closed vocabulary for `unresolved_reason`. Must stay in sync with
  the enum in `priv/schema/exchange_v3.json`'s `RequestShapeRecord`
  definition.
  """
  @spec unresolved_reasons() :: [String.t()]
  def unresolved_reasons, do: @unresolved_reasons

  @doc """
  Subset of `unresolved_reasons/0` that short-circuits derivation —
  the `Derive` orchestrator emits `nil` for every derivation field
  when the recipe is already terminally tagged at this reason.
  """
  @spec terminal_reasons() :: [String.t()]
  def terminal_reasons, do: @terminal_reasons

  @doc """
  Closed vocabulary for `body_encoding`.
  """
  @spec body_encodings() :: [String.t()]
  def body_encodings, do: @body_encodings

  @doc """
  Canonical Content-Type string for a given `body_encoding` value, or
  `nil` when the encoding implies no body / pure query (so no
  Content-Type to set).
  """
  @spec content_type_for(String.t() | nil) :: String.t() | nil
  def content_type_for(encoding) when is_binary(encoding) do
    Map.get(@content_type_for_encoding, encoding)
  end

  def content_type_for(_), do: nil

  @doc """
  Return `true` if every key in `derivation_fields/0` is present on
  the record AND populated. "Populated" means non-nil OR — for the
  one `content_type`/`body_encoding` exception — `content_type: nil`
  paired with `body_encoding: "none"` (no body → no Content-Type is
  honest-empty, not unresolved).

  Used by `CcxtExtract.RequestShape.Derive` (write-side flip) and
  `CcxtExtract.ContractTest` (read-side invariant) — shared
  predicate so both sites agree on "populated".
  """
  @spec all_derivation_fields_populated?(term()) :: boolean()
  def all_derivation_fields_populated?(record) when is_map(record) do
    Enum.all?(@derivation_fields, fn key -> field_populated?(record, key) end)
  end

  def all_derivation_fields_populated?(_), do: false

  defp field_populated?(record, "content_type") do
    case {Map.fetch(record, "content_type"), Map.fetch(record, "body_encoding")} do
      # `content_type: nil` paired with `body_encoding: "none"` is the
      # honest-empty case — no body to send, so no Content-Type.
      {{:ok, nil}, {:ok, "none"}} -> true
      {{:ok, nil}, _} -> false
      {{:ok, _value}, _} -> true
      {:error, _} -> false
    end
  end

  defp field_populated?(record, key) do
    case Map.fetch(record, key) do
      {:ok, nil} -> false
      {:ok, _value} -> true
      :error -> false
    end
  end

  @doc """
  Return the all-null scaffold for a single record. Used as the
  default value for every authenticated section before Phase 11
  derivation flips fields into place.
  """
  @spec null_record() :: record()
  def null_record do
    %{
      "endpoints" => nil,
      "body_encoding" => nil,
      "content_type" => nil,
      "unresolved_reason" => @initial_unresolved_reason,
      "patch_count" => 0
    }
  end

  @doc """
  Build the default `section_name => record` map from a list of
  authenticated section names.

  Accepts `nil` (exchange has no `sign()` AST) or an empty list
  (sign() exists but no `checkRequiredCredentials()` gates) — both
  return an empty map, which is the Honesty-Rule-correct shape:
  "this exchange authenticates zero sections, here are zero
  request shapes."

  Duplicate section names collapse; the caller is trusted on
  ordering.
  """
  @spec build_default([String.t()] | nil) :: record_map()
  def build_default(nil), do: %{}
  def build_default([]), do: %{}

  def build_default(auth_sections) when is_list(auth_sections) do
    Map.new(auth_sections, fn section when is_binary(section) ->
      {section, null_record()}
    end)
  end
end

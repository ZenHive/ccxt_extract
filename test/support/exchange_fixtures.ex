defmodule CcxtExtract.Test.ExchangeFixtures do
  @moduledoc """
  Schema-conformant exchange maps for contract-test unit tests.

  `schema_conformant/2` returns a map that covers every pointer declared
  by `CcxtExtract.Provenance` (`raw_pointers/0 ++ derived_pointers/0`)
  at the granularity the `provenance_covers_schema` contract invariant
  expects. Fixtures built from this helper don't produce noise findings
  against that invariant — callers can layer per-test payloads on top
  via `put_in/3` (e.g. to populate `runtime.describe.has` or flip a
  `_provenance` tag).

  Shared by `CcxtExtract.ContractTestTest` and
  `Mix.Tasks.CcxtExtract.ContractTestTaskTest`. Compiled only under
  `MIX_ENV=test` (see `mix.exs` `elixirc_paths(:test)`).
  """

  alias CcxtExtract.Provenance
  alias CcxtExtract.RequestShape
  alias CcxtExtract.SignRecipe
  alias CcxtExtract.TransactionClassification

  @doc """
  Returns a schema-conformant exchange map with top-level `"id" => id`
  AND nested `"exchange" => %{"id" => id, ...}`. Both contract tests
  and the `Mix.Tasks.CcxtExtract.ContractTest` task resolve exchange
  identity from either location, so both are populated.

  Options:

    * `:describe` — value for `runtime.describe` (default: `%{}`)
    * `:unified_endpoints` — value for `structure.unified_endpoints`
      (default: `%{}`). When provided, `structure.transaction_classification`
      is auto-derived from the keys via `TransactionClassification.derive/1`
      so the two stay in lockstep by construction.
    * `:request_defaults` — value for `structure.request_defaults`
      (default: `%{}`)
    * `:authenticated_sections` — list of section names (default: `[]`).
      `structure.sign_recipe` is derived from this list via
      `SignRecipe.build_default/1`, so the two stay in lockstep by
      construction (matches the `sign_recipe_keys_match_auth_sections`
      contract invariant). Tests that want to drift the two intentionally
      should `put_in/3` after construction.

  Any field not exposed as an option is set to `nil`, `[]`, or `%{}`
  so the map walks cleanly under every declared pointer. Tests that
  need a different shape should `put_in/3` into the returned map.
  """
  @spec schema_conformant(binary(), keyword()) :: map()
  def schema_conformant(id, opts \\ []) when is_binary(id) do
    describe = Keyword.get(opts, :describe, %{})
    unified_endpoints = Keyword.get(opts, :unified_endpoints, %{})
    request_defaults = Keyword.get(opts, :request_defaults, %{})
    auth_sections = Keyword.get(opts, :authenticated_sections, [])

    %{
      "id" => id,
      "exchange" => %{
        "id" => id,
        "name" => id,
        "certified" => false,
        "pro" => false,
        "version" => nil,
        "country" => [],
        "alias" => false,
        "referral" => nil,
        "tier" => "tier3"
      },
      "runtime" => %{
        "describe" => describe,
        "symbols_index" => nil,
        "symbol_patterns" => %{},
        "url_templates" => nil,
        "testnet_urls" => CcxtExtract.TestnetUrls.none_record(),
        "request_headers" => CcxtExtract.RequestHeaders.empty_record()
      },
      "structure" => %{
        "class_info" => nil,
        "methods" => nil,
        "sign_method" => nil,
        "authenticated_sections" => auth_sections,
        "sign_recipe" => SignRecipe.build_default(auth_sections),
        "request_shape" => RequestShape.build_default(auth_sections),
        "handle_errors" => %{
          "method" => nil,
          "exceptions" => nil,
          "http_exceptions" => nil,
          "error_code_fields" => [],
          "throw_dispatches" => []
        },
        "error_class_hierarchy" => %{
          "tree" => %{"BaseError" => %{}},
          "flat_parents" => %{"BaseError" => nil},
          "ancestors" => %{"BaseError" => []}
        },
        "interface_signatures" => nil,
        "pagination" => nil,
        "overrides" => nil,
        "unified_endpoints" => unified_endpoints,
        "transaction_classification" => TransactionClassification.derive(unified_endpoints),
        "request_defaults" => request_defaults,
        "rate_limit_costs" => nil,
        "error_dispatch" => nil,
        "sign_dispatch" => nil,
        "parse_dispatch" => nil,
        "rate_limit_buckets" => CcxtExtract.RateLimitBuckets.empty_record()
      },
      "_provenance" => Provenance.build_default()
    }
  end
end

defmodule CcxtExtract.Test.ExchangeFixtures do
  @moduledoc """
  Schema-conformant exchange maps for contract-test unit tests.

  `schema_conformant/2` returns a v4-shaped map that covers every pointer
  declared by `CcxtExtract.Provenance.raw_pointers_v4/0` /
  `derived_pointers_v4/0` at the granularity the `provenance_covers_schema`
  contract invariant expects. Fixtures built from this helper don't
  produce noise findings against that invariant — callers can layer
  per-test payloads on top via `put_in/3` (e.g. to populate
  `raw.describe.has` or flip a `_provenance` tag).

  Shared by `CcxtExtract.ContractTestTest` and
  `Mix.Tasks.CcxtExtract.ContractTestTaskTest`. Compiled only under
  `MIX_ENV=test` (see `mix.exs` `elixirc_paths(:test)`).
  """

  alias CcxtExtract.Normalization
  alias CcxtExtract.Provenance
  alias CcxtExtract.RequestShape
  alias CcxtExtract.SignRecipe
  alias CcxtExtract.TransactionClassification

  @doc """
  Returns a v4-shaped schema-conformant exchange map with top-level
  `"id" => id` AND nested `"exchange" => %{"id" => id, ...}`. Both
  contract tests and the `Mix.Tasks.CcxtExtract.ContractTest` task
  resolve exchange identity from either location, so both are populated.

  Options:

    * `:describe` — value for `raw.describe` (default: `%{}`)
    * `:unified_endpoints` — value for `endpoints.unified`
      (default: `%{}`). When provided, `endpoints.transaction_classification`
      is auto-derived from the keys via `TransactionClassification.derive/1`
      so the two stay in lockstep by construction.
    * `:request_defaults` — value for `endpoints.request.defaults`
      (default: `%{}`)
    * `:authenticated_sections` — list of section names (default: `[]`).
      `auth.sign_recipe` is derived from this list via
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
      "endpoints" => %{
        "unified" => unified_endpoints,
        "transaction_classification" => TransactionClassification.derive(unified_endpoints),
        "interfaces" => nil,
        "pagination" => nil,
        "request" => %{
          "defaults" => request_defaults,
          "shape" => RequestShape.build_default(auth_sections)
        },
        "handlers" => %{
          "error" => nil,
          "signing" => nil,
          "parse" => nil
        }
      },
      "auth" => %{
        "sign_recipe" => SignRecipe.build_default(auth_sections),
        "sign_method" => nil,
        "authenticated_sections" => auth_sections,
        "headers" => CcxtExtract.RequestHeaders.empty_record()
      },
      "errors" => %{
        "handle_errors" => %{
          "method" => nil,
          "exceptions" => nil,
          "http_exceptions" => nil,
          "error_code_fields" => [],
          "throw_dispatches" => []
        },
        "class_hierarchy" => %{
          "tree" => %{"BaseError" => %{}},
          "flat_parents" => %{"BaseError" => nil},
          "ancestors" => %{"BaseError" => []}
        },
        "status_map" => nil,
        "retry_classification" => nil
      },
      "rate_limits" => %{
        "buckets" => CcxtExtract.RateLimitBuckets.empty_record(),
        "per_endpoint_cost" => nil,
        "endpoint_cost_binding" => nil
      },
      "normalization" => Normalization.build(nil, nil),
      "markets" => %{
        "symbols_index" => nil,
        "patterns" => %{}
      },
      "testnet" => CcxtExtract.TestnetUrls.none_record(),
      "raw" => %{
        "describe" => describe,
        "url_templates" => nil,
        "class_info" => nil,
        "method_inventory" => nil,
        "overrides_meta" => nil
      },
      "_provenance" => Provenance.build_default()
    }
  end
end

[
  # MapSet opaque type warnings — known Elixir limitation
  # https://github.com/elixir-lang/elixir/issues/9078
  {"lib/ccxt_extract/method_analysis.ex", :call_without_opaque},
  {"lib/ccxt_extract/market_validation.ex", :call_without_opaque},
  {"lib/ccxt_extract/family_analysis.ex", :call_without_opaque},
  {"lib/ccxt_extract/summary.ex", :call_without_opaque},
  {"lib/ccxt_extract/overrides.ex", :call_without_opaque},
  {"lib/ccxt_extract/overrides.ex", :call_with_opaque},
  {"lib/ccxt_extract/unified_endpoints.ex", :call_without_opaque},
  {"lib/ccxt_extract/unified_endpoints.ex", :call_with_opaque},
  {"lib/ccxt_extract/pipeline.ex", :call_without_opaque},
  {"lib/ccxt_extract/pipeline.ex", :call_with_opaque},
  {"lib/ccxt_extract/error_code_fields/bindings.ex", :call_without_opaque},
  {"lib/ccxt_extract/error_code_fields/bindings.ex", :call_with_opaque},
  {"lib/mix/tasks/ccxt_extract.update.ex", :call_without_opaque},
  {"lib/ccxt_extract/validation.ex", :call_without_opaque},
  {"lib/ccxt_extract/scope.ex", :call_without_opaque},
  {"lib/ccxt_extract/scope_cleanup.ex", :call_without_opaque},
  {"lib/ccxt_extract/fixture_parity.ex", :call_without_opaque},
  {"lib/ccxt_extract/signing_fixtures.ex", :call_without_opaque},
  {"lib/ccxt_extract/discovery_loader.ex", :call_without_opaque},
  {"lib/ccxt_extract/contract_test.ex", :call_without_opaque},
  # Task 123: expand_nested/2 filters map keys against a MapSet; Dialyzer cannot
  # see through the opaque MapSet internals — same known Elixir limitation.
  {"lib/ccxt_extract/authenticated_sections.ex", :call_without_opaque},
  # Task 4: MapSet.t() scope arguments flow through the four QuickBEAM-backed
  # extractor modules; warnings surface where the MapSet is unpacked/iterated
  # (load_markets also in its Mix task because scope is forwarded into
  # :exchanges via maybe_put_scope/2). Shape-only, same opaque issue as the
  # entries above. Merge-path behavior is covered by the regression tests in
  # test/mix/tasks/quickbeam_scope_flags_test.exs and url_templates_test.exs.
  {"lib/ccxt_extract/signing_fixtures.ex", :call_with_opaque},
  {"lib/ccxt_extract/describe.ex", :call_with_opaque},
  {"lib/ccxt_extract/load_markets.ex", :call_with_opaque},
  {"lib/ccxt_extract/load_markets.ex", :call_without_opaque},
  {"lib/mix/tasks/ccxt_extract.load_markets.ex", :call_without_opaque},
  # Task 12: alias-aware scope guards. `MapSet.t(String.t())` spec for
  # alias_ids!/1 and exclude_aliases/1 trips the opaque-subtype check —
  # same Elixir limitation as the block above. Covered by
  # test/ccxt_extract/aliases_test.exs.
  {"lib/ccxt_extract/aliases.ex", :contract_with_opaque},
  # JSV uses runtime: false — Dialyzer can't see its types/functions
  {"lib/ccxt_extract/validation.ex", :unknown_type},
  {"lib/ccxt_extract/validation.ex", :unknown_function}
]

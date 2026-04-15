[
  # MapSet opaque type warnings — known Elixir limitation
  # https://github.com/elixir-lang/elixir/issues/9078
  {"lib/ccxt_extract/method_analysis.ex", :call_without_opaque},
  {"lib/ccxt_extract/market_validation.ex", :call_without_opaque},
  {"lib/ccxt_extract/family_analysis.ex", :call_without_opaque},
  {"lib/ccxt_extract/overrides.ex", :call_without_opaque},
  {"lib/ccxt_extract/overrides.ex", :call_with_opaque},
  {"lib/ccxt_extract/unified_endpoints.ex", :call_without_opaque},
  {"lib/ccxt_extract/unified_endpoints.ex", :call_with_opaque},
  {"lib/ccxt_extract/pipeline.ex", :call_without_opaque},
  {"lib/ccxt_extract/error_code_fields/bindings.ex", :call_without_opaque},
  {"lib/ccxt_extract/error_code_fields/bindings.ex", :call_with_opaque},
  {"lib/mix/tasks/ccxt_extract.update.ex", :call_without_opaque},
  {"lib/ccxt_extract/validation.ex", :call_without_opaque},
  {"lib/ccxt_extract/scope.ex", :call_without_opaque},
  {"lib/ccxt_extract/scope_cleanup.ex", :call_without_opaque},
  {"lib/ccxt_extract/fixture_parity.ex", :call_without_opaque},
  {"lib/ccxt_extract/signing_fixtures.ex", :call_without_opaque},
  # JSV uses runtime: false — Dialyzer can't see its types/functions
  {"lib/ccxt_extract/validation.ex", :unknown_type},
  {"lib/ccxt_extract/validation.ex", :unknown_function}
]

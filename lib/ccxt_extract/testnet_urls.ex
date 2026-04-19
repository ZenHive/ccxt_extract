defmodule CcxtExtract.TestnetUrls do
  @moduledoc """
  Derive a structured testnet / sandbox URL catalog from the CCXT `describe()`
  blob.

  ## Why

  `runtime.describe.urls.test` and `runtime.describe.options.sandboxMode` are
  already shipped as part of the raw `runtime.describe` passthrough, but a
  consumer that relies on them today has to reach into an opaque
  `additionalProperties: true` blob, resolve `{hostname}` templates itself, and
  silently fall through to production URLs when `urls.test` is absent but a
  `sandboxMode` flag exists. This module promotes both signals into a
  structured, derived, provenance-tagged field so consumers read one canonical
  shape instead of re-implementing CCXT's quirks.

  ## Output Structure

  Returns a map with four keys (never `nil`):

      %{
        "pattern" => "separate_host" | "sandbox_flag" | "none",
        "urls" => %{String.t() => term()} | nil,
        "sandbox_flag_field" => String.t() | nil,
        "unresolved_reason" => nil | "no_testnet_data"
      }

  * `pattern: "separate_host"` — `describe.urls.test` is a non-empty map.
    `urls` is that map with `{hostname}` placeholders substituted using
    `describe.hostname`. May coexist with `sandbox_flag_field` (okx does
    both: same-host URL + flag header).
  * `pattern: "sandbox_flag"` — `describe.options.sandboxMode` exists but
    `urls.test` is absent / empty. `urls` is `nil`; `sandbox_flag_field`
    names the flag key (`"sandboxMode"`).
  * `pattern: "none"` — neither signal present. `urls` and
    `sandbox_flag_field` are both `nil`; `unresolved_reason` is
    `"no_testnet_data"`.

  `sandbox_flag_field` is populated *independently* of `pattern` — it tracks
  whether the exchange carries a `sandboxMode`-style flag in `options`. This
  is the single-source-of-truth on flag presence regardless of whether the
  URL set is separate or shared.

  ## Honesty Rule

  No guesses. Commented-out `urls.test` blocks in CCXT source (htx) are not
  observable from describe — those fall into `"none"`. If a `{hostname}`
  placeholder can't be resolved (no `hostname` in describe), the literal
  `{hostname}` stays in the URL string and the `testnet_urls_shape_valid`
  contract invariant flags it as a finding.

  ## Pure Derivation

  No IO, no AST, no QuickBEAM. Microsecond-scale. Called inline during
  pipeline assembly with the already-loaded describe blob.
  """

  @sandbox_flag_key "sandboxMode"

  @doc """
  Derive the testnet URL catalog from a describe map.

  Accepts `nil` or a describe map and always returns a structured record.
  """
  @spec derive(map() | nil) :: map()
  def derive(nil), do: none_record()

  def derive(describe) when is_map(describe) do
    urls = Map.get(describe, "urls") || %{}
    test_urls_raw = Map.get(urls, "test")
    options = Map.get(describe, "options") || %{}
    hostname = Map.get(describe, "hostname")

    sandbox_flag_field = detect_sandbox_flag(options)

    cond do
      non_empty_map?(test_urls_raw) ->
        %{
          "pattern" => "separate_host",
          "urls" => resolve_hostname(test_urls_raw, hostname),
          "sandbox_flag_field" => sandbox_flag_field,
          "unresolved_reason" => nil
        }

      not is_nil(sandbox_flag_field) ->
        %{
          "pattern" => "sandbox_flag",
          "urls" => nil,
          "sandbox_flag_field" => sandbox_flag_field,
          "unresolved_reason" => nil
        }

      true ->
        none_record()
    end
  end

  def derive(_), do: none_record()

  @doc false
  @spec none_record() :: map()
  def none_record do
    %{
      "pattern" => "none",
      "urls" => nil,
      "sandbox_flag_field" => nil,
      "unresolved_reason" => "no_testnet_data"
    }
  end

  @doc """
  The set of `pattern` enum values. Exposed for the contract invariant.
  """
  @spec patterns() :: [String.t()]
  def patterns, do: ["separate_host", "sandbox_flag", "none"]

  @doc """
  The set of `unresolved_reason` values. Exposed for the contract invariant.
  """
  @spec unresolved_reasons() :: [String.t()]
  def unresolved_reasons, do: ["no_testnet_data"]

  @doc """
  The set of required keys in a testnet_urls record. Exposed for the
  contract invariant.
  """
  @spec required_keys() :: [String.t()]
  def required_keys, do: ["pattern", "urls", "sandbox_flag_field", "unresolved_reason"]

  # --- Helpers ---

  defp non_empty_map?(value) when is_map(value) and map_size(value) > 0, do: true
  defp non_empty_map?(_), do: false

  # Only reports the flag if the key is present in options. Value can be
  # false/true/nil — presence is what matters; runtime flips it.
  defp detect_sandbox_flag(options) when is_map(options) do
    if Map.has_key?(options, @sandbox_flag_key), do: @sandbox_flag_key
  end

  defp detect_sandbox_flag(_), do: nil

  # Walk leaf strings, substitute {hostname}. Preserves structure (flat or
  # nested maps). Leaves non-string leaves and non-map/non-string branches
  # untouched.
  defp resolve_hostname(value, hostname) when is_binary(value) and is_binary(hostname) do
    String.replace(value, "{hostname}", hostname)
  end

  defp resolve_hostname(value, _hostname) when is_binary(value), do: value

  defp resolve_hostname(value, hostname) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, resolve_hostname(v, hostname)} end)
  end

  defp resolve_hostname(value, hostname) when is_list(value) do
    Enum.map(value, &resolve_hostname(&1, hostname))
  end

  defp resolve_hostname(value, _hostname), do: value
end

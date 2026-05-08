defmodule CcxtExtract.RateLimitBucketsTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.RateLimitBuckets

  describe "derive/1" do
    test "binance — multi-axis (throttle + 60s rolling window)" do
      describe = %{
        "id" => "binance",
        "rateLimit" => 50,
        "rollingWindowSize" => 60_000.0
      }

      result = RateLimitBuckets.derive(describe)

      assert %{
               "buckets" => [bucket],
               "source" => "describe",
               "unresolved_reason" => nil
             } = result

      assert bucket["rate_limit_ms"] == 50
      assert bucket["rolling_window_ms"] == 60_000.0
      assert bucket["axes"] == ["request"]
      # algorithm defaults to leakyBucket — binance does NOT override
      # rateLimiterAlgorithm, so even though it ships rollingWindowSize,
      # initRestRateLimiter resolves algorithm = leakyBucket. The rolling
      # window dimension is the multi-axis signal, captured separately.
      assert bucket["algorithm"] == "leakyBucket"
      assert_in_delta bucket["refill_per_sec"], 20.0, 1.0e-6
    end

    test "deribit — single-axis (throttle only, no rolling window)" do
      describe = %{
        "id" => "deribit",
        "rateLimit" => 50
      }

      result = RateLimitBuckets.derive(describe)

      assert %{
               "buckets" => [bucket],
               "source" => "describe",
               "unresolved_reason" => nil
             } = result

      assert bucket["rate_limit_ms"] == 50
      assert bucket["rolling_window_ms"] == nil
      assert bucket["algorithm"] == "leakyBucket"
      assert_in_delta bucket["refill_per_sec"], 20.0, 1.0e-6
    end

    test "kraken — counter-based (1 req/sec leaky bucket)" do
      describe = %{
        "id" => "kraken",
        "rateLimit" => 1000
      }

      result = RateLimitBuckets.derive(describe)

      assert %{"buckets" => [bucket], "unresolved_reason" => nil} = result

      assert bucket["rate_limit_ms"] == 1000
      assert bucket["rolling_window_ms"] == nil
      # Kraken's per-key counter model is not represented in CCXT's runtime
      # — CCXT throttles every request through this single 1-token-per-sec
      # bucket. The wire-level counter is documented but not modelled.
      assert bucket["algorithm"] == "leakyBucket"
      assert_in_delta bucket["refill_per_sec"], 1.0, 1.0e-6
    end

    test "honors explicit rateLimiterAlgorithm override" do
      describe = %{
        "rateLimit" => 100,
        "rateLimiterAlgorithm" => "rollingWindow",
        "rollingWindowSize" => 30_000
      }

      assert %{"buckets" => [bucket]} = RateLimitBuckets.derive(describe)
      assert bucket["algorithm"] == "rollingWindow"
      assert bucket["rolling_window_ms"] == 30_000
    end

    test "honors explicit tokenBucket overrides for capacity + cost" do
      describe = %{
        "rateLimit" => 200,
        "tokenBucket" => %{
          "capacity" => 5,
          "cost" => 2,
          "algorithm" => "rollingWindow"
        }
      }

      assert %{"buckets" => [bucket]} = RateLimitBuckets.derive(describe)
      assert bucket["max_size"] == 5
      assert bucket["cost_default"] == 2
      # tokenBucket.algorithm wins over rateLimiterAlgorithm field
      assert bucket["algorithm"] == "rollingWindow"
    end

    test "missing rateLimit → empty buckets + rate_limit_unset reason" do
      describe = %{"id" => "broken"}

      assert %{
               "buckets" => [],
               "source" => "describe",
               "unresolved_reason" => "rate_limit_unset"
             } = RateLimitBuckets.derive(describe)
    end

    test "negative or zero rateLimit → rate_limit_unset" do
      assert %{"unresolved_reason" => "rate_limit_unset"} =
               RateLimitBuckets.derive(%{"rateLimit" => 0})

      assert %{"unresolved_reason" => "rate_limit_unset"} =
               RateLimitBuckets.derive(%{"rateLimit" => -1})
    end

    test "nil describe → instantiation_failed" do
      assert %{
               "buckets" => [],
               "source" => "describe",
               "unresolved_reason" => "instantiation_failed"
             } = RateLimitBuckets.derive(nil)
    end

    test "non-map input collapses to instantiation_failed" do
      assert %{"unresolved_reason" => "instantiation_failed"} =
               RateLimitBuckets.derive("garbage")
    end

    test "rolling_window_ms is positive only — zero collapses to nil" do
      describe = %{"rateLimit" => 50, "rollingWindowSize" => 0}
      assert %{"buckets" => [bucket]} = RateLimitBuckets.derive(describe)
      assert bucket["rolling_window_ms"] == nil
    end

    test "tokenBucket capacity/cost defaults to 1 when missing or non-positive" do
      describe = %{"rateLimit" => 100, "tokenBucket" => %{}}
      assert %{"buckets" => [bucket]} = RateLimitBuckets.derive(describe)
      assert bucket["max_size"] == 1
      assert bucket["cost_default"] == 1

      describe2 = %{"rateLimit" => 100, "tokenBucket" => %{"capacity" => 0, "cost" => -3}}
      assert %{"buckets" => [bucket2]} = RateLimitBuckets.derive(describe2)
      assert bucket2["max_size"] == 1
      assert bucket2["cost_default"] == 1
    end
  end

  describe "empty_record/0" do
    test "returns the always-emit wrapper used as pipeline-side fallback" do
      assert %{
               "buckets" => [],
               "source" => "describe",
               "unresolved_reason" => "no_discovery_entry"
             } = RateLimitBuckets.empty_record()
    end
  end

  describe "vocabulary helpers" do
    test "required_keys/0 matches what the schema declares" do
      assert RateLimitBuckets.required_keys() == ["buckets", "source", "unresolved_reason"]
    end

    test "required_bucket_keys/0 matches the per-bucket schema" do
      assert RateLimitBuckets.required_bucket_keys() == [
               "axes",
               "rate_limit_ms",
               "refill_per_sec",
               "max_size",
               "cost_default",
               "algorithm",
               "rolling_window_ms"
             ]
    end

    test "unresolved_reasons/0 enumerates the closed-vocabulary tags" do
      assert "instantiation_failed" in RateLimitBuckets.unresolved_reasons()
      assert "rate_limit_unset" in RateLimitBuckets.unresolved_reasons()
      assert "no_discovery_entry" in RateLimitBuckets.unresolved_reasons()
    end

    test "sources/0 enumerates the closed-vocabulary source tags" do
      assert RateLimitBuckets.sources() == ["describe", "tokenBucket", "method_body"]
    end
  end

  describe "write!/2 envelope stats" do
    test "computes with_bucket and with_rolling_window from final entries" do
      tmp = Path.join(System.tmp_dir!(), "rl_buckets_#{System.unique_integer([:positive])}.json")
      on_exit(fn -> File.rm(tmp) end)

      results = [
        %{
          "id" => "binance",
          "rate_limit_buckets" => RateLimitBuckets.derive(%{"rateLimit" => 50, "rollingWindowSize" => 60_000})
        },
        %{"id" => "deribit", "rate_limit_buckets" => RateLimitBuckets.derive(%{"rateLimit" => 50})},
        %{"id" => "kraken", "rate_limit_buckets" => RateLimitBuckets.derive(%{"rateLimit" => 1000})},
        # an exchange whose extractor produced no usable bucket — counts as no bucket
        %{"id" => "broken", "rate_limit_buckets" => RateLimitBuckets.derive(%{})}
      ]

      :ok = RateLimitBuckets.write!(results, output_path: tmp)

      decoded = tmp |> File.read!() |> Jason.decode!()
      assert decoded["count"] == 4
      assert decoded["with_bucket"] == 3
      assert decoded["with_rolling_window"] == 1

      # Entries sorted by id so the on-disk file is deterministic.
      assert Enum.map(decoded["exchanges"], & &1["id"]) ==
               ["binance", "broken", "deribit", "kraken"]
    end

    test "scoped write merges with existing file (out-of-scope entries preserved)" do
      tmp = Path.join(System.tmp_dir!(), "rl_buckets_#{System.unique_integer([:positive])}.json")
      on_exit(fn -> File.rm(tmp) end)

      original = [
        %{"id" => "binance", "rate_limit_buckets" => RateLimitBuckets.derive(%{"rateLimit" => 50})},
        %{"id" => "kraken", "rate_limit_buckets" => RateLimitBuckets.derive(%{"rateLimit" => 1000})}
      ]

      :ok = RateLimitBuckets.write!(original, output_path: tmp)

      # Re-run for kraken only with a different (larger) rateLimit.
      updated = [
        %{"id" => "kraken", "rate_limit_buckets" => RateLimitBuckets.derive(%{"rateLimit" => 2000})}
      ]

      :ok = RateLimitBuckets.write!(updated, output_path: tmp, scope: MapSet.new(["kraken"]))

      decoded = tmp |> File.read!() |> Jason.decode!()

      assert decoded["count"] == 2
      assert Enum.map(decoded["exchanges"], & &1["id"]) == ["binance", "kraken"]

      # Binance is preserved at its original rate limit; kraken is replaced.
      [binance, kraken] = decoded["exchanges"]
      [bbucket] = binance["rate_limit_buckets"]["buckets"]
      [kbucket] = kraken["rate_limit_buckets"]["buckets"]
      assert bbucket["rate_limit_ms"] == 50
      assert kbucket["rate_limit_ms"] == 2000
    end
  end

  describe "derive/1 produces records that conform to required_*_keys" do
    test "populated record has all required wrapper keys" do
      result = RateLimitBuckets.derive(%{"rateLimit" => 50})

      for key <- RateLimitBuckets.required_keys() do
        assert Map.has_key?(result, key), "missing wrapper key: #{key}"
      end
    end

    test "populated bucket entry has all required bucket keys" do
      %{"buckets" => [bucket]} = RateLimitBuckets.derive(%{"rateLimit" => 50})

      for key <- RateLimitBuckets.required_bucket_keys() do
        assert Map.has_key?(bucket, key), "missing bucket key: #{key}"
      end
    end

    test "empty record has all required wrapper keys" do
      result = RateLimitBuckets.empty_record()

      for key <- RateLimitBuckets.required_keys() do
        assert Map.has_key?(result, key), "missing wrapper key: #{key}"
      end
    end
  end
end

defmodule CcxtExtract.RateLimitCostBindingTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.RateLimitCostBinding

  describe "derive/1" do
    test "nil when unresolved_reason is set" do
      wrapper = %{
        "buckets" => [
          %{
            "axes" => ["request"],
            "rate_limit_ms" => 50.0,
            "refill_per_sec" => 20.0,
            "max_size" => 1.0,
            "cost_default" => 1.0,
            "algorithm" => "leakyBucket",
            "rolling_window_ms" => 0.0
          }
        ],
        "source" => "describe",
        "unresolved_reason" => "rate_limit_unset"
      }

      assert RateLimitCostBinding.derive(wrapper) == nil
    end

    test "nil when buckets list is empty" do
      wrapper = %{
        "buckets" => [],
        "source" => "describe",
        "unresolved_reason" => nil
      }

      assert RateLimitCostBinding.derive(wrapper) == nil
    end

    test "positive case: binds index 0 and copies axes from first bucket" do
      wrapper = %{
        "buckets" => [
          %{
            "axes" => ["request"],
            "rate_limit_ms" => 50.0,
            "refill_per_sec" => 20.0,
            "max_size" => 1.0,
            "cost_default" => 1.0,
            "algorithm" => "leakyBucket",
            "rolling_window_ms" => 0.0
          }
        ],
        "source" => "describe",
        "unresolved_reason" => nil
      }

      assert RateLimitCostBinding.derive(wrapper) == %{
               "bucket_index" => 0,
               "axes" => ["request"]
             }
    end

    test "nil for non-map input" do
      assert RateLimitCostBinding.derive(:not_a_map) == nil
    end

    test "nil when buckets value is not a list" do
      wrapper = %{
        "buckets" => "invalid",
        "source" => "describe",
        "unresolved_reason" => nil
      }

      assert RateLimitCostBinding.derive(wrapper) == nil
    end

    test "nil when first bucket lacks :axes key" do
      wrapper = %{
        "buckets" => [%{"rate_limit_ms" => 50.0}],
        "source" => "describe",
        "unresolved_reason" => nil
      }

      assert RateLimitCostBinding.derive(wrapper) == nil
    end

    test "nil when first bucket :axes is not a list" do
      wrapper = %{
        "buckets" => [%{"axes" => "request"}],
        "source" => "describe",
        "unresolved_reason" => nil
      }

      assert RateLimitCostBinding.derive(wrapper) == nil
    end
  end
end
